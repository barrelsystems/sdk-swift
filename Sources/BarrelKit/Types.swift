import Foundation

public let protocolVersion = 1

public struct InitConfig: Sendable {
  public var credential: String
  public var baseURL: String?
  /// Developer-configurable; the server-enforced floor is 15 minutes regardless of what's passed here.
  public var checkInInterval: TimeInterval?
  public var attributes: [String: String]
  public var autoDownload: Bool
  /// Off by default. Logs what the SDK is doing via `print` -- never noisy unless opted in.
  public var debug: Bool
  /// Overrides Sparkle's own feed URL for this run. Never set outside a
  /// developer's own test/staging setup -- a real app configures its feed
  /// via `SUFeedURL` in its own Info.plist instead.
  public var updateFeedURL: String?
  /// How long a cached `held` Policy is honored without reconfirmation
  /// before failing open. Default 24h; `initialize()` throws synchronously
  /// if this exceeds the 7-day ceiling.
  public var holdCacheMaxAge: TimeInterval?

  public init(
    credential: String,
    baseURL: String? = nil,
    checkInInterval: TimeInterval? = nil,
    attributes: [String: String] = [:],
    autoDownload: Bool = true,
    debug: Bool = false,
    updateFeedURL: String? = nil,
    holdCacheMaxAge: TimeInterval? = nil
  ) {
    self.credential = credential
    self.baseURL = baseURL
    self.checkInInterval = checkInInterval
    self.attributes = attributes
    self.autoDownload = autoDownload
    self.debug = debug
    self.updateFeedURL = updateFeedURL
    self.holdCacheMaxAge = holdCacheMaxAge
  }
}

/// The stable, cross-platform fingerprint for a classified update failure.
/// `unknown` is load-bearing, not a fallback that "shouldn't happen" --
/// some native paths have no library-sourced identifier at all.
public enum UpdateFailureMode: String, Sendable, Codable {
  case manifestUnreachable = "manifest-unreachable"
  case manifestParseFailed = "manifest-parse-failed"
  case versionInvalid = "version-invalid"
  case signatureMissing = "signature-missing"
  case signatureInvalid = "signature-invalid"
  case signatureVersionMismatch = "signature-version-mismatch"
  case checksumMismatch = "checksum-mismatch"
  case downloadTransportFailed = "download-transport-failed"
  case downloadFileInvalid = "download-file-invalid"
  case downloadSizeExceeded = "download-size-exceeded"
  case downloadStreamIncomplete = "download-stream-incomplete"
  case diffPatchIncompatible = "diff-patch-incompatible"
  case extractionFailed = "extraction-failed"
  case targetNotFoundInManifest = "target-not-found-in-manifest"
  case tempStorageConstraint = "temp-storage-constraint"
  case installWriteFailed = "install-write-failed"
  case installAuthRequiredOrFailed = "install-auth-required-or-failed"
  case installDowngradeBlocked = "install-downgrade-blocked"
  case installRelaunchFailed = "install-relaunch-failed"
  case installMissingUpdate = "install-missing-update"
  case configInvalid = "config-invalid"
  case corsMisconfigured = "cors-misconfigured"
  case platformUnsupported = "platform-unsupported"
  case translocationBlocked = "translocation-blocked"
  case webkitTerminated = "webkit-terminated"
  case releaseNotesFailed = "release-notes-failed"
  case resumeAppcastFailed = "resume-appcast-failed"
  case unknown = "unknown"
}

public enum Phase: String, Sendable, Codable {
  case check, verify, download, extract, install, config, unknown
}

public enum AdapterState: Sendable, Equatable {
  case idle
  case checking
  case available(releaseNotes: String?)
  case downloading(progress: Int?)
  case downloaded
  case updateCancelled
  case failed(category: FailureCategory, code: UpdateFailureMode, platformCode: String)

  public enum FailureCategory: String, Sendable, Codable {
    case check, download, updater
  }
}

extension AdapterState: Codable {
  private enum CodingKeys: String, CodingKey {
    case type, progress, category, code, platformCode, releaseNotes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "idle": self = .idle
    case "checking": self = .checking
    case "available":
      self = .available(releaseNotes: try container.decodeIfPresent(String.self, forKey: .releaseNotes))
    case "downloading":
      self = .downloading(progress: try container.decodeIfPresent(Int.self, forKey: .progress))
    case "downloaded": self = .downloaded
    case "update-cancelled": self = .updateCancelled
    case "failed":
      self = .failed(
        category: try container.decode(FailureCategory.self, forKey: .category),
        code: try container.decode(UpdateFailureMode.self, forKey: .code),
        platformCode: try container.decode(String.self, forKey: .platformCode)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container, debugDescription: "Unknown AdapterState type \(type)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .idle: try container.encode("idle", forKey: .type)
    case .checking: try container.encode("checking", forKey: .type)
    case .available(let releaseNotes):
      try container.encode("available", forKey: .type)
      try container.encodeIfPresent(releaseNotes, forKey: .releaseNotes)
    case .downloading(let progress):
      try container.encode("downloading", forKey: .type)
      try container.encodeIfPresent(progress, forKey: .progress)
    case .downloaded: try container.encode("downloaded", forKey: .type)
    case .updateCancelled: try container.encode("update-cancelled", forKey: .type)
    case .failed(let category, let code, let platformCode):
      try container.encode("failed", forKey: .type)
      try container.encode(category, forKey: .category)
      try container.encode(code, forKey: .code)
      try container.encode(platformCode, forKey: .platformCode)
    }
  }
}

/// Resolved from a static lookup table at return time -- never persisted or transmitted.
public struct UpdateFailure: Sendable, Codable, Equatable {
  public var phase: Phase
  public var failureMode: UpdateFailureMode
  public var title: String
  public var platform: String
  public var platformCode: String

  public init(phase: Phase, failureMode: UpdateFailureMode, title: String, platform: String, platformCode: String) {
    self.phase = phase
    self.failureMode = failureMode
    self.title = title
    self.platform = platform
    self.platformCode = platformCode
  }
}

public enum Policy: Sendable, Equatable {
  case current(issuedAt: String, environment: String)
  case held(issuedAt: String, environment: String, reason: String?, until: String?)
  case updateEligible(issuedAt: String, environment: String, priority: String?)
}

extension Policy: Codable {
  private enum CodingKeys: String, CodingKey {
    case type, issuedAt, environment, reason, until, priority
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    let issuedAt = try container.decode(String.self, forKey: .issuedAt)
    let environment = try container.decode(String.self, forKey: .environment)
    switch type {
    case "current": self = .current(issuedAt: issuedAt, environment: environment)
    case "held":
      self = .held(
        issuedAt: issuedAt, environment: environment,
        reason: try container.decodeIfPresent(String.self, forKey: .reason),
        until: try container.decodeIfPresent(String.self, forKey: .until))
    case "updateEligible":
      self = .updateEligible(
        issuedAt: issuedAt, environment: environment,
        priority: try container.decodeIfPresent(String.self, forKey: .priority))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container, debugDescription: "Unknown Policy type \(type)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .current(let issuedAt, let environment):
      try container.encode("current", forKey: .type)
      try container.encode(issuedAt, forKey: .issuedAt)
      try container.encode(environment, forKey: .environment)
    case .held(let issuedAt, let environment, let reason, let until):
      try container.encode("held", forKey: .type)
      try container.encode(issuedAt, forKey: .issuedAt)
      try container.encode(environment, forKey: .environment)
      try container.encodeIfPresent(reason, forKey: .reason)
      try container.encodeIfPresent(until, forKey: .until)
    case .updateEligible(let issuedAt, let environment, let priority):
      try container.encode("updateEligible", forKey: .type)
      try container.encode(issuedAt, forKey: .issuedAt)
      try container.encode(environment, forKey: .environment)
      try container.encodeIfPresent(priority, forKey: .priority)
    }
  }

  public var type: String {
    switch self {
    case .current: return "current"
    case .held: return "held"
    case .updateEligible: return "updateEligible"
    }
  }
}

/// The wire shape the backend's schema actually expects -- flatter than the
/// internally persisted `BufferedFact` (see `toWireBufferedFact`).
public struct WireBufferedFact: Encodable, Sendable {
  public var kind: String
  public var firstObservedAt: String
  public var lastObservedAt: String
  public var occurrenceCount: Int
  public var state: AdapterState?
  public var phase: Phase?
  public var failureMode: UpdateFailureMode?
  public var platformCode: String?
}

public struct CheckInRequest: Encodable, Sendable {
  public var protocolVersion: Int
  public var installationId: String
  public var eventId: String
  public var checkedInAt: String
  public var sdkVersion: String
  public var observedVersion: String
  public var platform: String
  public var arch: String
  public var osVersion: String
  public var attributes: [String: String]
  public var adapterState: AdapterState
  public var bufferedFacts: [WireBufferedFact]
}

public struct CheckInResponse: Decodable, Sendable {
  public var protocolVersion: Int
  public var policy: String
  public var signature: String
  /// A key-rotation announcement: a new public key, signed by the key this
  /// SDK currently trusts. Both absent when no rotation is in flight.
  public var nextPublicKeyPem: String?
  public var nextPublicKeySignature: String?
}
