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

/// Asks whether it's still safe to act right now -- narrower than a full
/// check-in, no state sync. Any failure (network, non-2xx, bad signature)
/// fails open: the caller proceeds exactly as it would under a `current` Policy.
func checkPreAction(_ params: PreActionCheckParams) async -> Policy? {
  struct Body: Encodable {
    var protocolVersion: Int
    var installationId: String
    var stage: String
  }
  let body = Body(
    protocolVersion: protocolVersion, installationId: params.connection.installationId, stage: params.stage.rawValue)

  guard
    let parsed = await postProtocolRequest(
      PostProtocolRequestParams(
        baseURL: params.connection.baseURL, path: "pre-action-check", credential: params.connection.credential,
        body: body, label: "pre-action-check", log: params.log, session: params.session))
  else { return nil }

  return verifyAndParsePolicy(parsed, publicKeyPEM: params.trustedKeyPEM)
}
