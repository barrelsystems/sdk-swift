import BarrelKit
import Foundation

/// Mirrors the conformance harness's own normative wire shapes --
/// this is this platform's independent copy.
struct Capabilities: Encodable {
  let sdkName: String
  let sdkVersion: String
  let supportsCheckIn: Bool
}

struct CreateAdapterResponse: Encodable {
  let id: String
}

struct CreateAdapterRequest: Decodable {
  let channel: String?
  let checkInBaseUrl: String
  let publicKeyPem: String
  let variant: String?
}

struct JitterFractionRequest: Decodable {
  let installationId: String
}

struct JitterFractionResponse: Encodable {
  let fraction: Double
}

/// The harness's own counterpart treats `result` as opaque since its shape
/// differs per command -- this is generic over whatever each call site
/// actually returns rather than one fixed type.
struct ResultWrapper<T: Encodable>: Encodable {
  let result: T
}

struct FactObservation: Codable, Sendable {
  let kind: String
  let state: AdapterState?
  let platformCode: String?
}
