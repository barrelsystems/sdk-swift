import Foundation

/// The check-in wire protocol's own version, sent on every request and
/// bumped only on a breaking change to its shape.
let protocolVersion = 1

/// Where and who: every protocol-level request (check-in, pre-action-check,
/// and the cadence/host-control layers that trigger them) needs all three
/// of these together, never a subset.
struct BackendConnection: Sendable {
  var baseURL: String
  var credential: String
  var installationId: String
}

/// The wire shape the backend's schema actually expects -- flatter than the
/// internally persisted `BufferedFact` (see `toWireBufferedFact`).
struct WireBufferedFact: Encodable, Sendable {
  /// Either `"lifecycleState"` or `"updateError"`, naming which of the
  /// optional fields below are populated.
  var kind: String
  var firstObservedAt: String
  var lastObservedAt: String
  var occurrenceCount: Int
  /// Set when `kind == "lifecycleState"`.
  var state: Updates.State?
  /// Set when `kind == "updateError"`.
  var phase: Updates.Phase?
  /// Set when `kind == "updateError"`.
  var failureMode: Updates.FailureMode?
  /// Set when `kind == "updateError"`.
  var platformCode: String?
}

/// The body of every check-in request this SDK sends.
struct CheckInRequest: Encodable, Sendable {
  var protocolVersion: Int
  /// Stable per-install identifier, generated once and persisted to disk.
  var installationId: String
  /// A fresh identifier per check-in, letting the server de-duplicate retries.
  var eventId: String
  /// ISO 8601, set at the moment this request is built.
  var checkedInAt: String
  var sdkVersion: String
  var channel: String
  /// The app version this installation is currently running.
  var observedVersion: String
  var platform: String
  var arch: String
  var osVersion: String
  var attributes: [String: String]
  var lifecycleState: Updates.State
  var bufferedFacts: [WireBufferedFact]
  /// Clamped nominal interval in milliseconds, before scheduling jitter.
  var checkInIntervalMs: Int
}

/// The raw response to a check-in, before its signature is verified and
/// `updateEligibility` is parsed into an `Updates.Eligibility`.
struct CheckInResponse: Decodable, Sendable {
  var protocolVersion: Int
  /// JSON-encoded `Updates.Eligibility`, verified against `signature` before
  /// parsing.
  var updateEligibility: String
  /// Base64-encoded signature over `updateEligibility`'s raw bytes.
  var signature: String
  /// A key-rotation announcement: a new key, signed by the key this
  /// SDK currently trusts. Both absent when no rotation is in flight.
  var nextPublicKeyPem: String?
  var nextPublicKeySignature: String?
}
