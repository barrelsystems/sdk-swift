import Foundation

enum PreActionStage: String, Sendable {
  case preDownload = "pre-download"
  case preApply = "pre-apply"
}

struct PreActionCheckParams: Sendable {
  var connection: BackendConnection
  var stage: PreActionStage
  var trustedKeyPEM: String
  var log: (@Sendable (String) -> Void)?
  var session: URLSession = .shared
}

/// Authorize only the pending action, without state synchronization; invalid or unavailable
/// responses fail open.
func checkPreAction(_ params: PreActionCheckParams) async -> Updates.Eligibility? {
  struct Body: Encodable {
    var protocolVersion: Int
    var installationId: String
    var stage: String
  }
  let body = Body(
    protocolVersion: protocolVersion, installationId: params.connection.installationId,
    stage: params.stage.rawValue)

  guard
    let parsed = await postProtocolRequest(
      PostProtocolRequestParams(
        baseURL: params.connection.baseURL, path: "pre-action-check",
        credential: params.connection.credential,
        body: body, label: "pre-action-check", log: params.log, session: params.session))
  else { return nil }

  return verifyAndParseUpdateEligibility(parsed, publicKeyPEM: params.trustedKeyPEM)
}
