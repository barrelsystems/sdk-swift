import Foundation

@testable import BarrelKit

@MainActor
final class AdapterInstance {
  let runtime: BarrelKit
  let probe: UpdaterProbe
  let dataDirectory: URL

  var adapter: SparkleUpdaterAdapter {
    guard let adapter = runtime.adapter else { preconditionFailure("SDK has not initialized") }
    return adapter
  }

  init(checkInBaseURL: String, publicKeyPEM: String, channel: String) {
    let probe = UpdaterProbe()
    self.probe = probe
    dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("barrel-runtime-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
      let key = try JSONEncoder().encode(["publicKeyPEM": publicKeyPEM])
      try key.write(to: dataDirectory.appendingPathComponent("barrel-trusted-key.json"))
    } catch { preconditionFailure("Could not create isolated SDK storage: \(error)") }

    runtime = BarrelKit(environment: RuntimeEnvironment(
      hostBundle: makeTestHostBundle(), dataDirectory: dataDirectory,
      makeAdapter: { bundle, facts in
        let adapter = SparkleUpdaterAdapter(hostBundle: bundle, bufferedFactsStore: facts, checkForUpdates: { probe.checkForUpdates() })
        probe.adapter = adapter
        return adapter
      },
      scheduleCadence: { CadenceTicker(params: $0) }))
    do { try runtime.initialize(InitConfig(credential: "test-service", baseURL: checkInBaseURL, channel: channel, autoDownload: false)) }
    catch { preconditionFailure("Invalid test runtime config: \(error)") }
  }
}

final class AdapterRegistry: @unchecked Sendable {
  private let adapters: Locked<[String: AdapterInstance]> = Locked([:])

  func create(_ request: CreateAdapterRequest) -> String {
    let id = UUID().uuidString
    let instance = runOnMain {
      AdapterInstance(
        checkInBaseURL: request.checkInBaseUrl, publicKeyPEM: request.publicKeyPem,
        channel: request.channel ?? "stable")
    }

    runBlocking(fallback: ()) { await instance.runtime.ready() }
    adapters.write { $0[id] = instance }
    return id
  }

  func get(_ id: String) -> AdapterInstance? {
    adapters.read { $0[id] }
  }

  func destroy(_ id: String) {
    if let instance = adapters.read({ $0[id] }) {
      let directory = runOnMain { instance.dataDirectory }
      try? FileManager.default.removeItem(at: directory)
    }
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
    let id = registry.create(createRequest)
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
      return .json(200, ResultWrapper(result: runOnMain { instance.runtime.getAdapterState() }))
    case "getPolicy":
      return .json(200, ResultWrapper(result: runOnMain { instance.runtime.getPolicy() }))
    case "getLastUpdateError":
      return .json(200, ResultWrapper(result: runOnMain { instance.runtime.getLastUpdateError() }))
    case "getUpdaterActivity":
      return .json(200, ResultWrapper(result: runOnMain { instance.probe.activity }))
    case "checkNow":
      runBlocking(fallback: ()) { await instance.runtime.checkNow() }
      return .json(200, ResultWrapper<String?>(result: nil))
    case "prepareAction", "runAction":
      guard let stageRaw = body["stage"] as? String, let stage = PreActionStage(rawValue: stageRaw) else {
        return .empty(404)
      }
      if command == "prepareAction" {
        runOnMain { instance.probe.prepare(stage: stage) }
      } else {
        runOnMain {
          if stage == .preDownload { instance.runtime.downloadUpdate() }
          else { instance.runtime.applyUpdate() }
        }
      }
      runBlocking(fallback: ()) { await instance.runtime.waitForActions() }
      return .json(200, ResultWrapper(result: runOnMain { instance.probe.activity }))
    case "getInternalDefectCount":
      guard let cause = body["cause"] as? String else { return .empty(404) }
      return .json(200, ResultWrapper(result: runOnMain { InternalDefects.counts(for: cause) }))
    case "injectEvent":
      let eventName = body["eventName"] as? String ?? ""
      let payload = body["payload"] as? [String: Any] ?? [:]
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
