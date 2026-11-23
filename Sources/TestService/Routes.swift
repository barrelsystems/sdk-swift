import Foundation

@testable import BarrelKit

func route(_ request: HttpRequest) -> HttpResponse {
  let components = request.path.split(separator: "/", omittingEmptySubsequences: true).map(
    String.init)

  if request.method == "GET" && components == [] {
    return .json(200, Capabilities(sdkName: "swift", sdkVersion: "0.0.1", supportsCheckIn: true))
  }

  if request.method == "POST" && components == ["adapters"] {
    guard
      let createRequest = try? JSONDecoder().decode(CreateAdapterRequest.self, from: request.body)
    else {
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
    case "prepareUpdaterFailure":
      runOnMain {
        instance.adapter.showUpdaterError(
          NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
          acknowledgement: {})
      }
      return .json(200, ResultWrapper<String?>(result: nil))
    case "getUpdateState":
      return .json(
        200, ResultWrapper(result: runOnMain { instance.runtime.updates.snapshot().state }))
    case "getUpdateEligibility":
      return .json(
        200, ResultWrapper(result: runOnMain { instance.runtime.updates.snapshot().eligibility }))
    case "getLastUpdateError":
      return .json(
        200, ResultWrapper(result: runOnMain { instance.runtime.updates.snapshot().lastError }))
    case "getUpdaterActivity":
      return .json(200, ResultWrapper(result: runOnMain { instance.probe.activity }))
    case "checkNow":
      runBlocking(fallback: ()) { await instance.runtime.updates.checkNow() }
      return .json(200, ResultWrapper<String?>(result: nil))
    case "prepareAction", "runAction":
      guard let stageRaw = body["stage"] as? String, let stage = PreActionStage(rawValue: stageRaw)
      else {
        return .empty(404)
      }
      if command == "prepareAction" {
        runOnMain { instance.probe.prepare(stage: stage) }
      } else {
        runBlocking(fallback: ()) {
          // A denial/failure here is a normal, observable outcome for this
          // endpoint -- the probe's own activity counters report it, not a
          // propagated error.
          do {
            if stage == .preDownload {
              try await instance.runtime.updates.download()
            } else {
              try await instance.runtime.updates.apply()
            }
          } catch {}
        }
      }
      runBlocking(fallback: ()) { await instance.runtime.updates.waitForActions() }
      return .json(200, ResultWrapper(result: runOnMain { instance.probe.activity }))
    default:
      return .empty(404)
    }
  }

  if request.method == "POST" && components == ["pure", "jitter-fraction"] {
    guard let body = try? JSONDecoder().decode(JitterFractionRequest.self, from: request.body)
    else {
      return .empty(404)
    }
    let fraction = computeJitterFraction(installationId: body.installationId)
    return .json(200, JitterFractionResponse(fraction: fraction))
  }

  return .empty(404)
}
