import Foundation

/// The check-in wire protocol's own version, sent on every request and
/// bumped only on a breaking change to its shape.
public let protocolVersion = 1

/// Where and who: every protocol-level request (check-in, pre-action-check,
/// and the cadence/host-control layers that trigger them) needs all three
/// of these together, never a subset.
struct BackendConnection: Sendable {
  var baseURL: String
  var credential: String
  var installationId: String
}

/// Config passed to `initialize()`. `credential` is the only required field.
public struct InitConfig: Sendable {
  /// The SDK credential issued by Barrel for this app.
  public var credential: String
  /// Where check-ins are sent. Omit to use Barrel's own production endpoint.
  public var baseURL: String?
  /// Developer-configurable; the server-enforced floor is 15 minutes regardless of what's passed here.
  public var checkInInterval: TimeInterval?
  /// Arbitrary key-value pairs sent with every check-in, for segmenting
  /// policy decisions (e.g. a release channel or cohort).
  public var attributes: [String: String]
  /// On by default. When off, a found update is never downloaded.
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
  /// Could not reach the update manifest.
  case manifestUnreachable = "manifest-unreachable"
  /// The update manifest could not be parsed.
  case manifestParseFailed = "manifest-parse-failed"
  /// The update manifest's version is invalid.
  case versionInvalid = "version-invalid"
  /// The update manifest has no signature.
  case signatureMissing = "signature-missing"
  /// The update manifest's signature is invalid.
  case signatureInvalid = "signature-invalid"
  /// The update's signed version doesn't match the manifest.
  case signatureVersionMismatch = "signature-version-mismatch"
  /// The update download failed at the network layer.
  case downloadTransportFailed = "download-transport-failed"
  /// The downloaded update could not be extracted.
  case extractionFailed = "extraction-failed"
  /// A temporary-storage constraint blocked the update.
  case tempStorageConstraint = "temp-storage-constraint"
  /// The update could not be written to disk.
  case installWriteFailed = "install-write-failed"
  /// The update install needs or failed authorization.
  case installAuthRequiredOrFailed = "install-auth-required-or-failed"
  /// The update was blocked as a version downgrade.
  case installDowngradeBlocked = "install-downgrade-blocked"
  /// The app could not relaunch after installing the update.
  case installRelaunchFailed = "install-relaunch-failed"
  /// The downloaded update file is missing at install time.
  case installMissingUpdate = "install-missing-update"
  /// The updater's configuration is invalid.
  case configInvalid = "config-invalid"
  /// This update isn't supported on the current platform.
  case platformUnsupported = "platform-unsupported"
  /// macOS App Translocation blocked the update.
  case translocationBlocked = "translocation-blocked"
  /// The updater's WebKit process terminated unexpectedly.
  case webkitTerminated = "webkit-terminated"
  /// The update's release notes could not be loaded.
  case releaseNotesFailed = "release-notes-failed"
  /// Resuming the update feed after a prior failure didn't work.
  case resumeAppcastFailed = "resume-appcast-failed"
  /// The app quit to apply an update, but never came back up on the new version.
  case applyNotConfirmed = "apply-not-confirmed"
  /// An unclassified update failure occurred.
  case unknown = "unknown"
}

/// Which stage of the pipeline a failure occurred in, at the granularity
/// `UpdateFailure.phase` reports.
public enum Phase: String, Sendable, Codable {
  case check, verify, download, extract, install, config, unknown
}

/// The updater's current lifecycle state, as `getAdapterState()` returns it
/// and as every check-in reports it.
public enum AdapterState: Sendable, Equatable {
  /// No check has run yet, or the last one found nothing.
  case idle
  /// A check is in flight.
  case checking
  /// A check found an update not yet downloaded.
  case available(releaseNotes: String?)
  /// The update is downloading. `progress` is 0-100 when Sparkle reports one.
  case downloading(progress: Int?)
  /// The update finished downloading and is ready to install.
  case downloaded
  /// The user or Sparkle cancelled an in-progress download or install.
  case updateCancelled
  /// Something in the check/download/install pipeline failed.
  case failed(category: FailureCategory, code: UpdateFailureMode, platformCode: String)

  /// Which coarse grouping a `failed` state's `code` belongs to.
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

/// `getLastUpdateError()`'s own return shape -- the fields a bare
/// `AdapterState.failed` doesn't carry.
public struct UpdateFailure: Sendable, Codable, Equatable {
  /// Which stage of the pipeline this failure occurred in.
  public var phase: Phase
  /// The stable, cross-platform fingerprint for what went wrong.
  public var failureMode: UpdateFailureMode
  /// Resolved from a static lookup table at return time -- never persisted or transmitted.
  public var title: String
  /// The canonical name of the adapter library this failure came from, e.g. `"sparkle"`.
  public var platform: String
  /// The adapter library's own error identifier, unmapped.
  public var platformCode: String

  public init(phase: Phase, failureMode: UpdateFailureMode, title: String, platform: String, platformCode: String) {
    self.phase = phase
    self.failureMode = failureMode
    self.title = title
    self.platform = platform
    self.platformCode = platformCode
  }
}

/// What a check-in response resolves to once its signature is verified.
public enum Policy: Sendable, Equatable {
  /// The installation is current; nothing to do.
  case current(issuedAt: String, environment: String)
  /// Barrel is unreachable or undecided -- keep the last-known policy in
  /// effect, no longer than `holdCacheMaxAge` allows.
  case held(issuedAt: String, environment: String, reason: String?, until: String?)
  /// An update is available and this installation is eligible for it.
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
  /// Either `"adapterState"` or `"updateError"`, naming which of the
  /// optional fields below are populated.
  public var kind: String
  public var firstObservedAt: String
  public var lastObservedAt: String
  public var occurrenceCount: Int
  /// Set when `kind == "adapterState"`.
  public var state: AdapterState?
  /// Set when `kind == "updateError"`.
  public var phase: Phase?
  /// Set when `kind == "updateError"`.
  public var failureMode: UpdateFailureMode?
  /// Set when `kind == "updateError"`.
  public var platformCode: String?
}

/// The body of every check-in request this SDK sends.
public struct CheckInRequest: Encodable, Sendable {
  public var protocolVersion: Int
  /// Stable per-install identifier, generated once and persisted to disk.
  public var installationId: String
  /// A fresh identifier per check-in, letting the server de-duplicate retries.
  public var eventId: String
  /// ISO 8601, set at the moment this request is built.
  public var checkedInAt: String
  public var sdkVersion: String
  /// The app version this installation is currently running.
  public var observedVersion: String
  public var platform: String
  public var arch: String
  public var osVersion: String
  public var attributes: [String: String]
  public var adapterState: AdapterState
  public var bufferedFacts: [WireBufferedFact]
}

/// The raw response to a check-in, before its signature is verified and
/// `policy` is parsed into a `Policy`.
public struct CheckInResponse: Decodable, Sendable {
  public var protocolVersion: Int
  /// JSON-encoded `Policy`, verified against `signature` before parsing.
  public var policy: String
  /// Base64-encoded signature over `policy`'s raw bytes.
  public var signature: String
  /// A key-rotation announcement: a new public key, signed by the key this
  /// SDK currently trusts. Both absent when no rotation is in flight.
  public var nextPublicKeyPem: String?
  public var nextPublicKeySignature: String?
}
