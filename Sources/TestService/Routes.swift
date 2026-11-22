import Foundation

@testable import BarrelKit

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

    if let response = handleResilienceCommand(command, body: body, instance: instance) {
      return response
    }

    if let response = handleBufferCommand(command, body: body, instance: instance) {
      return response
    }

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
