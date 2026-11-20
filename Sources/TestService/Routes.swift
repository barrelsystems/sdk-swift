import Foundation

@testable import BarrelKit

// `main.swift`'s own top-level code gets special main-actor treatment that
// an ordinary file's top-level code doesn't -- `AppcastServer`'s own state
// is already protected by its internal `Locked`, so this is genuinely safe.
nonisolated(unsafe) let appcastServer = AppcastServer()
let appcastPort = appcastServer.start()

/// `injectEvent`'s eventName names one of Sparkle's own `SPUUserDriver`
/// callbacks for NSObject-constructable cases, or "updateFound"/
/// "updateNotAvailable" for the ones that need a real `checkForUpdates()`.
@MainActor
final class AdapterInstance {
  let adapter: SparkleUpdaterAdapter
  // Mandatory on every `createAdapter` call; the Sparkle adapter above
  // stays independent of them -- check-in scenarios never touch it, and
  // adapter-event scenarios never touch check-in.
  let checkInBaseURL: String
  let publicKeyPEM: String
  let installationId = UUID().uuidString.lowercased()
  // Guards `checkNow` against a concurrent attempt on this same instance --
  // a second attempt while one is already in flight is skipped, not queued.
  let checkInLock = Locked<Bool>(false)

  init(checkInBaseURL: String, publicKeyPEM: String) {
    adapter = SparkleUpdaterAdapter(
      hostBundle: makeTestHostBundle(), bufferedFactsStore: BufferedFactsStore())
    adapter.setFeedURL("http://127.0.0.1:\(appcastPort)/appcast.xml")
    self.checkInBaseURL = checkInBaseURL
    self.publicKeyPEM = publicKeyPEM
  }
}

final class AdapterRegistry: @unchecked Sendable {
  private let adapters: Locked<[String: AdapterInstance]> = Locked([:])

  func create(checkInBaseURL: String, publicKeyPEM: String) -> String {
    let id = UUID().uuidString
    let instance = runOnMain { AdapterInstance(checkInBaseURL: checkInBaseURL, publicKeyPEM: publicKeyPEM) }
    adapters.write { $0[id] = instance }
    return id
  }

  func get(_ id: String) -> AdapterInstance? {
    adapters.read { $0[id] }
  }

  func destroy(_ id: String) {
    adapters.write { $0.removeValue(forKey: id) }
  }
}

let registry = AdapterRegistry()

func route(_ request: HttpRequest) -> HttpResponse {
  let components = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

  if request.method == "GET" && components == [] {
    return .json(200, Capabilities(sdkName: "swift", sdkVersion: "0.0.1", supportsCheckIn: true))
  }

  if request.method == "POST" && components == ["adapters"] {
    guard let createRequest = try? JSONDecoder().decode(CreateAdapterRequest.self, from: request.body) else {
      return .empty(404)
    }
    let id = registry.create(
      checkInBaseURL: createRequest.checkInBaseUrl, publicKeyPEM: createRequest.publicKeyPem)
    return .json(200, CreateAdapterResponse(id: id))
  }

  if request.method == "DELETE" && components.count == 2 && components[0] == "adapters" {
    registry.destroy(components[1])
    return .empty(204)
  }

  if request.method == "POST" && components.count == 3 && components[0] == "adapters"
    && components[2] == "commands"
  {
    guard let instance = registry.get(components[1]) else { return .empty(404) }
    guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
      let command = body["command"] as? String
    else { return .empty(404) }

    switch command {
    case "getAdapterState":
      return .json(200, ResultWrapper(result: runOnMain { instance.adapter.getAdapterState() }))
    case "getLastUpdateError":
      return .json(200, ResultWrapper(result: runOnMain { instance.adapter.getLastUpdateError() }))
    case "checkNow":
      var acquiredLock = false
      instance.checkInLock.write { inFlight in
        if !inFlight {
          inFlight = true
          acquiredLock = true
        }
      }

      guard acquiredLock else {
        // Skips, not queues -- matches the other platforms' explicit locks.
        return .json(200, ResultWrapper<String?>(result: nil))
      }
      defer { instance.checkInLock.write { $0 = false } }

      let adapterState = runOnMain { instance.adapter.getAdapterState() }
      let checkInParams = CheckInParams(
        baseURL: instance.checkInBaseURL, credential: "test-service",
        installationId: instance.installationId, sdkVersion: "0.0.1", attributes: [:],
        adapterState: adapterState, bufferedFacts: [])
      let response = runBlocking(fallback: nil) { await sendCheckIn(checkInParams) }
      if let response {
        _ = verifyAndParsePolicy(response, publicKeyPEM: instance.publicKeyPEM)
      }
      return .json(200, ResultWrapper<String?>(result: nil))
    case "triggerPreActionCheck":
      guard let stageRaw = body["stage"] as? String, let stage = PreActionStage(rawValue: stageRaw) else {
        return .empty(404)
      }
      let preActionParams = PreActionCheckParams(
        baseURL: instance.checkInBaseURL, credential: "test-service",
        installationId: instance.installationId, stage: stage, trustedKeyPEM: instance.publicKeyPEM)
      // Fails open to "current" -- `checkPreAction` resolves `nil` on any
      // network/signature failure, and a fail-open caller proceeds exactly
      // as it would under a `current` Policy.
      let policy = runBlocking(fallback: nil) { await checkPreAction(preActionParams) }
      return .json(200, ResultWrapper(result: policy?.type ?? "current"))
    case "getInternalDefectCount":
      guard let cause = body["cause"] as? String else { return .empty(404) }
      return .json(200, ResultWrapper(result: runOnMain { InternalDefects.counts(for: cause) }))
    case "injectEvent":
      let eventName = body["eventName"] as? String ?? ""
      let payload = body["payload"] as? [String: Any] ?? [:]
      if asyncInjectEvents.contains(eventName) {
        let settled = waitForSettledState(instance) {
          dispatchInjectEvent(instance, eventName: eventName, payload: payload)
        }
        return .json(200, ResultWrapper(result: settled))
      }
      runOnMain { dispatchInjectEvent(instance, eventName: eventName, payload: payload) }
      return .json(200, ResultWrapper<String?>(result: nil))
    default:
      return .empty(404)
    }
  }

  if request.method == "POST" && components == ["pure", "jitter-fraction"] {
    guard let body = try? JSONDecoder().decode(JitterFractionRequest.self, from: request.body) else {
      return .empty(404)
    }
    let fraction = computeJitterFraction(installationId: body.installationId)
    return .json(200, JitterFractionResponse(fraction: fraction))
  }

  return .empty(404)
}
