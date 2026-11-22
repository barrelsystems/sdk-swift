import Foundation

@testable import BarrelKit

struct BufferExitProbe: Codable {
  let directory: String
  let facts: [FactObservation]
  let mode: String
  var reload: Bool
}

func probeBufferExit(mode: String, facts: [FactObservation]) -> HttpResponse {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "barrel-buffer-exit-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }

  let probe = BufferExitProbe(directory: directory.path, facts: facts, mode: mode, reload: false)
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  guard let data = try? JSONEncoder().encode(probe),
    let config = String(data: data, encoding: .utf8)
  else { return .empty(500) }

  let output = Pipe()
  child.standardOutput = output
  child.environment = ProcessInfo.processInfo.environment.merging(["BARREL_BUFFER_PROBE": config]) {
    _, new in new
  }
  do { try child.run() } catch { return .empty(500) }
  child.waitUntilExit()

  guard child.terminationStatus == 0 else { return .empty(500) }

  let marker = output.fileHandleForReading.readDataToEndOfFile()
  let path = directory.appendingPathComponent("barrel-buffered-facts.json")
  guard let saved = try? Data(contentsOf: path),
    var result = try? JSONSerialization.jsonObject(with: saved) as? [String: Any]
  else { return .empty(500) }

  var reload = probe
  reload.reload = true
  let reader = Process()
  reader.executableURL = child.executableURL
  let recovered = Pipe()
  reader.standardOutput = recovered
  guard let config = try? JSONEncoder().encode(reload),
    let value = String(data: config, encoding: .utf8)
  else { return .empty(500) }
  reader.environment = ProcessInfo.processInfo.environment.merging(["BARREL_BUFFER_PROBE": value]) {
    _, new in new
  }
  do { try reader.run() } catch { return .empty(500) }
  reader.waitUntilExit()
  guard reader.terminationStatus == 0,
    let facts = try? JSONSerialization.jsonObject(
      with: recovered.fileHandleForReading.readDataToEndOfFile())
  else { return .empty(500) }

  result["recoveredFacts"] = facts
  result["pendingWriteObserved"] =
    String(data: marker, encoding: .utf8)?.hasPrefix("pending") ?? false
  guard let data = try? JSONSerialization.data(withJSONObject: ["result": result]) else {
    return .empty(500)
  }
  return HttpResponse(status: 200, body: data)
}

func runBufferExitProbe(_ probe: BufferExitProbe) async {
  let store = BufferedFactsStore()
  let path = URL(fileURLWithPath: probe.directory).appendingPathComponent(
    "barrel-buffered-facts.json"
  ).path
  await store.configure(filePath: path)

  if probe.reload {
    let snapshot = await store.snapshot()
    if let data = try? JSONEncoder().encode(snapshot),
      let value = String(data: data, encoding: .utf8)
    {
      print(value)
      fflush(stdout)
    }
    exit(0)
  }

  if probe.mode == "pending" { await setBufferPersistence(path: path, mode: .blocked) }
  for fact in probe.facts {
    await recordObservation(fact, store: store)
    if probe.mode == "pending" {
      let deadline = Date().addingTimeInterval(2)
      while !bufferPersistenceControls.gate(for: path).blockedWrite {
        guard Date() < deadline else { exit(1) }
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
  }

  if probe.mode == "pending" {
    print("pending")
    fflush(stdout)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      bufferPersistenceControls.gate(for: path).release()
    }
  } else {
    await PersistenceWriter.waitForPendingWrites()
    // Only the production atexit handler can recreate this file.
    try? FileManager.default.removeItem(atPath: path)
  }

  exit(0)
}
