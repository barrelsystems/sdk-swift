import Foundation

/// The backend's schema expects `updateError` facts flattened, not
/// nested under `failure` with its extra `title`/`platform` fields --
/// those are resolved for local display, never meant to cross the wire.
func toWireBufferedFact(_ fact: BufferedFact) -> WireBufferedFact {
  switch fact {
  case .adapterState(let state, let first, let last, let count):
    return WireBufferedFact(
      kind: "adapterState", firstObservedAt: first, lastObservedAt: last, occurrenceCount: count,
      state: state, phase: nil, failureMode: nil, platformCode: nil)
  case .updateError(let failure, let first, let last, let count):
    return WireBufferedFact(
      kind: "updateError", firstObservedAt: first, lastObservedAt: last, occurrenceCount: count,
      state: nil, phase: failure.phase, failureMode: failure.failureMode, platformCode: failure.platformCode)
  }
}

struct CheckInParams: Sendable {
  var connection: BackendConnection
  var sdkVersion: String
  var channel: String
  var attributes: [String: String]
  var adapterState: AdapterState
  var bufferedFacts: [BufferedFact]
  var log: (@Sendable (String) -> Void)?
  var session: URLSession = .shared
}

/// Sends one check-in attempt with a bounded timeout. There is no retry loop
/// here by design -- any failure (network error, non-2xx, timeout) resolves
/// to `nil`, and the caller's next scheduled tick is the retry.
func sendCheckIn(_ params: CheckInParams) async -> CheckInResponse? {
  let env = collectEnvironment()
  let body = CheckInRequest(
    protocolVersion: protocolVersion,
    installationId: params.connection.installationId,
    eventId: UUID().uuidString.lowercased(),
    checkedInAt: ISO8601DateFormatter().string(from: Date()),
    sdkVersion: params.sdkVersion,
    channel: params.channel,
    observedVersion: env.observedVersion,
    platform: env.platform,
    arch: env.arch,
    osVersion: env.osVersion,
    attributes: boundAttributes(params.attributes),
    adapterState: params.adapterState,
    bufferedFacts: params.bufferedFacts.map(toWireBufferedFact)
  )

  return await postProtocolRequest(
    PostProtocolRequestParams(
      baseURL: params.connection.baseURL, path: "check-in", credential: params.connection.credential, body: body,
      label: "check-in", log: params.log, session: params.session))
}
