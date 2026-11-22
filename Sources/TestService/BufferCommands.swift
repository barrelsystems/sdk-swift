import Foundation

@testable import BarrelKit

func recordObservation(_ fact: FactObservation, store: BufferedFactsStore) async {
  if fact.kind == "adapterState", let state = fact.state {
    await store.recordAdapterState(state)
  } else if fact.kind == "updateError", let code = fact.platformCode {
    await store.recordUpdateError(
      UpdateFailure(
        phase: .download, failureMode: .unknown,
        title: "Derived display text", platform: "sparkle", platformCode: code))
  }
}

func readBufferResponse(path: String) -> HttpResponse {
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
    let object = try? JSONSerialization.jsonObject(with: data),
    let result = try? JSONSerialization.data(withJSONObject: ["result": object])
  else { return .empty(500) }

  return HttpResponse(status: 200, body: result)
}

func handleBufferCommand(_ command: String, body: [String: Any], instance: AdapterInstance)
  -> HttpResponse?
{
  switch command {
  case "setBufferPersistence":
    guard let value = body["mode"] as? String, let mode = BufferPersistenceMode(rawValue: value)
    else { return .empty(400) }
    let path = runOnMain {
      instance.dataDirectory.appendingPathComponent("barrel-buffered-facts.json").path
    }
    runBlocking(fallback: ()) { await setBufferPersistence(path: path, mode: mode) }
    return .json(200, ResultWrapper<String?>(result: nil))
  case "getBufferPersistenceState":
    let path = runOnMain {
      instance.dataDirectory.appendingPathComponent("barrel-buffered-facts.json").path
    }
    return .json(
      200,
      ResultWrapper(result: ["blockedWrite": bufferPersistenceControls.gate(for: path).blockedWrite]
      ))
  case "recordFacts", "probeBufferExit":
    guard let objects = body["facts"],
      let data = try? JSONSerialization.data(withJSONObject: objects),
      let facts = try? JSONDecoder().decode([FactObservation].self, from: data)
    else { return .empty(400) }

    if command == "probeBufferExit" {
      guard let mode = body["mode"] as? String else { return .empty(400) }
      return probeBufferExit(mode: mode, facts: facts)
    }

    let concurrent = body["concurrent"] as? Bool ?? false
    let store = runOnMain { instance.runtime.bufferedFactsStore }

    runBlocking(fallback: ()) {
      if concurrent {
        await withTaskGroup(of: Void.self) { group in
          for fact in facts { group.addTask { await recordObservation(fact, store: store) } }
        }
      } else {
        for fact in facts { await recordObservation(fact, store: store) }
      }
    }
    return .json(200, ResultWrapper<String?>(result: nil))
  case "getBufferedFacts", "clearBuffer":
    let store = runOnMain { instance.runtime.bufferedFactsStore }

    if command == "clearBuffer" {
      runBlocking(fallback: ()) { await store.clear(sent: await store.snapshot()) }
      return .json(200, ResultWrapper<String?>(result: nil))
    }
    return .json(
      200, ResultWrapper(result: runBlocking(fallback: [BufferedFact]()) { await store.snapshot() })
    )
  case "getPersistedBuffer":
    runBlocking(fallback: ()) { await PersistenceWriter.waitForPendingWrites() }
    return readBufferResponse(
      path: runOnMain {
        instance.dataDirectory.appendingPathComponent("barrel-buffered-facts.json").path
      })
  default:
    return nil
  }
}
