import AppKit
import Foundation

@testable import BarrelKit

func handleResilienceCommand(_ command: String, body: [String: Any], instance: AdapterInstance)
  -> HttpResponse?
{
  switch command {
  case "getCadenceState":
    let inFlight = runBlocking(fallback: false) {
      await instance.runtime.updates.cadenceIsChecking()
    }
    let interval = runBlocking(fallback: Double?.none) {
      await instance.runtime.updates.cadenceIntervalMs()
    }
    return .json(
      200,
      ResultWrapper(
        result: CadenceState(
          intervalMs: interval, inFlight: inFlight, logs: instance.debugMessages.read { $0 })))
  case "triggerLifecycle":
    guard let event = body["event"] as? String else { return .empty(400) }
    runOnMain {
      if event == "foreground" {
        NotificationCenter.default.post(
          name: NSApplication.didBecomeActiveNotification, object: nil)
      } else if event == "resume" {
        NSWorkspace.shared.notificationCenter.post(
          name: NSWorkspace.didWakeNotification, object: nil)
      }
    }
    return .json(200, ResultWrapper<String?>(result: nil))
  case "restoreInstallationPersistence":
    let path = runOnMain {
      instance.dataDirectory.appendingPathComponent("barrel-installation.json").path
    }
    try? FileManager.default.removeItem(atPath: path)
    return .json(200, ResultWrapper<String?>(result: nil))
  case "getPersistedInstallationId":
    runBlocking(fallback: ()) {
      await instance.runtime.updates.installationIdStore.waitForPendingPersistence()
    }
    let path = runOnMain {
      instance.dataDirectory.appendingPathComponent("barrel-installation.json")
    }
    let saved = (try? Data(contentsOf: path)).flatMap {
      try? JSONDecoder().decode([String: String].self, from: $0)
    }
    return .json(200, ResultWrapper(result: saved?["installationId"]))
  default: return nil
  }
}

private struct CadenceState: Encodable {
  let intervalMs: Double?
  let inFlight: Bool
  let logs: [String]
  let lifecycleEvents = ["foreground", "resume"]
}
