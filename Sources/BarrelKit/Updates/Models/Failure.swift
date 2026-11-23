import Foundation

extension Updates {
  /// Which coarse grouping a `failed` state's `code` belongs to.
  public enum FailureCategory: String, Sendable, Codable {
    case check, download, updater
  }

  /// The stable, cross-platform fingerprint for a classified update failure.
  /// `unknown` is load-bearing, not a fallback that "shouldn't happen" --
  /// some native paths have no library-sourced identifier at all.
  public enum FailureMode: String, Sendable, Codable {
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
  /// `Updates.Failure.phase` reports.
  public enum Phase: String, Sendable, Codable {
    case check, verify, download, extract, install, config, unknown
  }

  /// Classified native failure carried in the subscription’s `lastError` field.
  public struct Failure: Sendable, Codable, Equatable {
    /// Which stage of the pipeline this failure occurred in.
    public var phase: Updates.Phase
    /// The stable, cross-platform fingerprint for what went wrong.
    public var failureMode: Updates.FailureMode
    /// Resolved from a static lookup table at return time -- never persisted or transmitted.
    public var title: String
    /// The canonical name of the adapter library this failure came from, e.g. `"sparkle"`.
    public var platform: String
    /// The adapter library's own error identifier, unmapped.
    public var platformCode: String

    public init(
      phase: Updates.Phase, failureMode: Updates.FailureMode, title: String, platform: String,
      platformCode: String
    ) {
      self.phase = phase
      self.failureMode = failureMode
      self.title = title
      self.platform = platform
      self.platformCode = platformCode
    }
  }

}
