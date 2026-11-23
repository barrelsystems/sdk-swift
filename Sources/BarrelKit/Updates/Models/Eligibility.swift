import Foundation

extension Updates {

  /// What a check-in response resolves to once its signature is verified.
  public enum Eligibility: Sendable, Equatable {
    /// No hold or eligibility decision is in effect; proceed normally.
    case unrestricted(issuedAt: String, environment: String)
    /// A verified decision deferring update actions within its expiry/cache lifetime.
    case held(issuedAt: String, environment: String, reason: String?, until: String?)
    /// An update is available and this installation is eligible for it.
    case eligible(issuedAt: String, environment: String, priority: String?)
  }

}

extension Updates.Eligibility: Codable {
  private enum CodingKeys: String, CodingKey {
    case type, issuedAt, environment, reason, until, priority
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    let issuedAt = try container.decode(String.self, forKey: .issuedAt)
    let environment = try container.decode(String.self, forKey: .environment)
    switch type {
    case "unrestricted": self = .unrestricted(issuedAt: issuedAt, environment: environment)
    case "held":
      self = .held(
        issuedAt: issuedAt, environment: environment,
        reason: try container.decodeIfPresent(String.self, forKey: .reason),
        until: try container.decodeIfPresent(String.self, forKey: .until))
    case "eligible":
      self = .eligible(
        issuedAt: issuedAt, environment: environment,
        priority: try container.decodeIfPresent(String.self, forKey: .priority))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container, debugDescription: "Unknown Updates.Eligibility type \(type)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .unrestricted(let issuedAt, let environment):
      try container.encode("unrestricted", forKey: .type)
      try container.encode(issuedAt, forKey: .issuedAt)
      try container.encode(environment, forKey: .environment)
    case .held(let issuedAt, let environment, let reason, let until):
      try container.encode("held", forKey: .type)
      try container.encode(issuedAt, forKey: .issuedAt)
      try container.encode(environment, forKey: .environment)
      try container.encodeIfPresent(reason, forKey: .reason)
      try container.encodeIfPresent(until, forKey: .until)
    case .eligible(let issuedAt, let environment, let priority):
      try container.encode("eligible", forKey: .type)
      try container.encode(issuedAt, forKey: .issuedAt)
      try container.encode(environment, forKey: .environment)
      try container.encodeIfPresent(priority, forKey: .priority)
    }
  }

  public var type: String {
    switch self {
    case .unrestricted: return "unrestricted"
    case .held: return "held"
    case .eligible: return "eligible"
    }
  }
}
