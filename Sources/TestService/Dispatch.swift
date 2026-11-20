import Foundation

@testable import BarrelKit

/// `onStateChange`'s listener fires on the main actor; a plain class
/// (not an actor) is enough here since the background thread only reads
/// it after the semaphore the listener signals has already been waited on.
final class StateBox: @unchecked Sendable {
  var state: AdapterState?
}

/// Hops onto the main actor's executor synchronously, from the HTTP
/// server's own background thread, and back -- registration must stay
/// quick so Sparkle's real async network check can call back later.
func runOnMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
  DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}

/// Blocks the calling (background) thread until `instance`'s state
/// changes away from `.checking`, or `timeout` elapses. `updateFound`/
/// `updateNotAvailable` currently always time out; see `dispatchInjectEvent`.
func waitForSettledState(
  _ instance: AdapterInstance, timeout: TimeInterval = 5, trigger: @escaping @MainActor () -> Void
) -> AdapterState {
  let semaphore = DispatchSemaphore(value: 0)
  let box = StateBox()
  runOnMain {
    instance.adapter.onStateChange { newState in
      if case .checking = newState { return }
      box.state = newState
      semaphore.signal()
    }
    trigger()
  }
  _ = semaphore.wait(timeout: .now() + timeout)
  return box.state ?? .failed(category: .updater, code: .unknown, platformCode: "test-service-timeout")
}

/// Safe only because the calling thread is never one of Swift's own
/// concurrency-executor threads (this server runs on a plain, dedicated OS
/// thread) -- calling this inside a `Task` or `@MainActor` risks deadlock.
func runBlocking<T: Sendable>(
  timeout: TimeInterval = 15, fallback: T, _ operation: @escaping @Sendable () async -> T
) -> T {
  let semaphore = DispatchSemaphore(value: 0)
  let box: Locked<T?> = Locked(nil)

  Task {
    let result = await operation()
    box.write { $0 = result }
    semaphore.signal()
  }

  guard semaphore.wait(timeout: .now() + timeout) == .success else {
    return fallback
  }
  guard let result = box.read({ $0 }) else {
    preconditionFailure("runBlocking: operation finished without producing a result")
  }
  return result
}

/// `updateFound`/`updateNotAvailable` trigger a real, async Sparkle check;
/// every other event is a synchronous direct call whose resulting state
/// is already settled by the time this returns.
let asyncInjectEvents: Set<String> = ["updateFound", "updateNotAvailable"]

@MainActor
func dispatchInjectEvent(_ instance: AdapterInstance, eventName: String, payload: [String: Any]) {
  let adapter = instance.adapter
  switch eventName {
  case "checking":
    adapter.showUserInitiatedUpdateCheck(cancellation: {})
  case "updateFound":
    // KNOWN GAP: always times out -- `checkForUpdates()` never calls back
    // in a bare SPM executable, and `showUpdateFound` itself is
    // unreachable directly (`SPUUserUpdateState.init` is unavailable).
    let releaseNotes = payload["releaseNotes"] as? String
    appcastServer.setNextAppcastXML(
      appcastXML(
        version: "2.0.0", releaseNotes: releaseNotes, signature: "",
        feedBaseURL: "http://127.0.0.1:\(appcastPort)"))
    adapter.checkForUpdates()
  case "updateNotAvailable":
    appcastServer.setNoUpdate()
    adapter.checkForUpdates()
  case "downloadInitiated":
    adapter.showDownloadInitiated(cancellation: {})
  case "downloadProgress":
    let expected = (payload["expectedContentLength"] as? NSNumber)?.uint64Value
    let received = (payload["receivedLength"] as? NSNumber)?.uint64Value ?? 0
    if let expected { adapter.showDownloadDidReceiveExpectedContentLength(expected) }
    adapter.showDownloadDidReceiveData(ofLength: received)
  case "extractionProgress":
    // No-op: the real adapter has no separate "extracting" state, so
    // `showExtractionReceivedProgress` doesn't change `AdapterState` --
    // it stays whatever the preceding download progress already set.
    let progress = (payload["progress"] as? NSNumber)?.doubleValue ?? 0
    adapter.showExtractionReceivedProgress(progress)
  case "readyToInstall":
    adapter.showReady(toInstallAndRelaunch: { _ in })
  case "downloadBeforeAvailable":
    adapter.downloadUpdate()  // out of sequence -- records an internal defect, not a failure
  case "installBeforeDownloaded":
    adapter.quitAndInstall()  // out of sequence -- records an internal defect, not a failure
  case "updaterError":
    let code: OSStatus?
    if let codeName = payload["code"] as? String {
      code = sparkleErrorCode(named: codeName)
    } else {
      code = (payload["rawCode"] as? NSNumber)?.int32Value
    }
    guard let code else { return }
    let error = NSError(domain: "SUSparkleErrorDomain", code: Int(code))
    adapter.showUpdaterError(error, acknowledgement: {})
  default:
    break
  }
}
