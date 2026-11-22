import Foundation

@testable import BarrelKit

/// Routes run on background threads; UI-adjacent adapter work stays on the main actor.
func runOnMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
  DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
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

@MainActor
func dispatchInjectEvent(_ instance: AdapterInstance, eventName: String, payload: [String: Any]) {
  let adapter = instance.adapter
  switch eventName {
  case "checking":
    adapter.showUserInitiatedUpdateCheck(cancellation: {})
  case "updateFound":
    instance.probe.offerUpdate(releaseNotes: payload["releaseNotes"] as? String)
  case "updateNotAvailable":
    instance.probe.reportNoUpdate()
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
