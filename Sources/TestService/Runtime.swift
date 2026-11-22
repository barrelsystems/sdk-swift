import Foundation

@testable import BarrelKit

@MainActor
final class AdapterInstance {
  let runtime: BarrelKit
  let probe: UpdaterProbe
  let dataDirectory: URL
  let debugMessages = Locked<[String]>([])

  var adapter: SparkleUpdaterAdapter {
    guard let adapter = runtime.adapter else { preconditionFailure("SDK has not initialized") }
    return adapter
  }

  init(request: CreateAdapterRequest) {
    let messages = debugMessages
    let probe = UpdaterProbe()
    self.probe = probe
    dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "barrel-runtime-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
      let key = try JSONEncoder().encode(["publicKeyPEM": request.publicKeyPem])
      try key.write(to: dataDirectory.appendingPathComponent("barrel-trusted-key.json"))
    } catch { preconditionFailure("Could not create isolated SDK storage: \(error)") }

    if request.installationPersistence == "failed" {
      try? FileManager.default.createDirectory(
        at: dataDirectory.appendingPathComponent("barrel-installation.json"),
        withIntermediateDirectories: true)
    }

    runtime = BarrelKit(
      environment: RuntimeEnvironment(
        hostBundle: makeTestHostBundle(), dataDirectory: dataDirectory,
        makeAdapter: { bundle, facts in
          let adapter = SparkleUpdaterAdapter(
            hostBundle: bundle, bufferedFactsStore: facts,
            checkForUpdates: { probe.checkForUpdates() })
          probe.adapter = adapter
          return adapter
        },
        writeDebugLog: { message in messages.write { $0.append(message) } },
        scheduleCadence: { params in
          if request.lifecycle == true { return startCadence(params) }
          return CadenceTicker(params: params)
        }))
    do {
      try runtime.initialize(
        InitConfig(
          credential: "test-service", baseURL: request.checkInBaseUrl,
          checkInInterval: request.checkInIntervalMs.map { $0 / 1000 },
          attributes: request.attributes ?? [:], channel: request.channel ?? "stable",
          autoDownload: false,
          debug: request.debug ?? false
        ))
    } catch { preconditionFailure("Invalid test runtime config: \(error)") }
  }
}

final class AdapterRegistry: @unchecked Sendable {
  private let adapters: Locked<[String: AdapterInstance]> = Locked([:])

  func create(_ request: CreateAdapterRequest) -> String {
    let id = UUID().uuidString
    let instance = runOnMain {
      AdapterInstance(request: request)
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
      runBlocking(fallback: ()) {
        await instance.runtime.stopCadence()
        await PersistenceWriter.waitForPendingWrites()
      }
      try? FileManager.default.removeItem(at: directory)
    }
    adapters.write { $0.removeValue(forKey: id) }
  }
}

let registry = AdapterRegistry()
