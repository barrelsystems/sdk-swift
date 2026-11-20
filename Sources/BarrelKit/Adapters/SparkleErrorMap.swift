import Sparkle

/// Maps Sparkle's finite `SUError` codes onto this SDK's cross-platform
/// taxonomy. `SUNoUpdateError`/`SUInstallationCanceledError` are
/// deliberately absent -- non-failures the adapter special-cases first.
func mapSparkleError(_ code: OSStatus) -> (phase: Phase, failureMode: UpdateFailureMode) {
  switch code {
  // Signature verification
  case SUError.noPublicDSAFoundError.rawValue,
    SUError.insufficientSigningError.rawValue:
    return (.verify, .signatureMissing)
  case SUError.signatureError.rawValue,
    SUError.validationError.rawValue:
    return (.verify, .signatureInvalid)

  // Configuration
  case SUError.insecureFeedURLError.rawValue,
    SUError.invalidFeedURLError.rawValue,
    SUError.invalidUpdaterError.rawValue,
    SUError.invalidHostBundleIdentifierError.rawValue,
    SUError.incorrectAPIUsageError.rawValue,
    SUError.runningFromDiskImageError.rawValue:
    return (.config, .configInvalid)
  case SUError.invalidHostVersionError.rawValue: return (.config, .platformUnsupported)
  case SUError.runningTranslocated.rawValue: return (.config, .translocationBlocked)

  // Appcast / check phase
  case SUError.appcastParseError.rawValue: return (.check, .manifestParseFailed)
  case SUError.appcastError.rawValue: return (.check, .manifestUnreachable)
  case SUError.resumeAppcastError.rawValue: return (.check, .resumeAppcastFailed)
  case SUError.webKitTerminationError.rawValue: return (.check, .webkitTerminated)
  case SUError.releaseNotesError.rawValue: return (.check, .releaseNotesFailed)

  // Download
  case SUError.temporaryDirectoryError.rawValue: return (.download, .tempStorageConstraint)
  case SUError.downloadError.rawValue: return (.download, .downloadTransportFailed)

  // Extraction
  case SUError.unarchivingError.rawValue: return (.extract, .extractionFailed)

  // Installation
  case SUError.fileCopyFailure.rawValue,
    SUError.installationWriteNoPermissionError.rawValue:
    return (.install, .installWriteFailed)
  case SUError.authenticationFailure.rawValue,
    SUError.installationAuthorizeLaterError.rawValue:
    return (.install, .installAuthRequiredOrFailed)
  case SUError.missingUpdateError.rawValue,
    SUError.missingInstallerToolError.rawValue,
    SUError.notValidUpdateError.rawValue:
    return (.install, .installMissingUpdate)
  case SUError.relaunchError.rawValue,
    SUError.agentInvalidationError.rawValue:
    return (.install, .installRelaunchFailed)
  case SUError.installationError.rawValue: return (.install, .unknown)
  case SUError.downgradeError.rawValue: return (.install, .installDowngradeBlocked)

  default: return (.unknown, .unknown)
  }
}

/// The single source of truth for `SUError`'s raw code <-> real case-name
/// mapping, in both directions. `sparkleErrorCaseName` and
/// `sparkleErrorCode(named:)` are its only readers.
private let sparkleErrorNamesByCode: [OSStatus: String] = [
  SUError.noPublicDSAFoundError.rawValue: "SUNoPublicDSAFoundError",
  SUError.insufficientSigningError.rawValue: "SUInsufficientSigningError",
  SUError.insecureFeedURLError.rawValue: "SUInsecureFeedURLError",
  SUError.invalidFeedURLError.rawValue: "SUInvalidFeedURLError",
  SUError.invalidUpdaterError.rawValue: "SUInvalidUpdaterError",
  SUError.invalidHostBundleIdentifierError.rawValue: "SUInvalidHostBundleIdentifierError",
  SUError.invalidHostVersionError.rawValue: "SUInvalidHostVersionError",
  SUError.appcastParseError.rawValue: "SUAppcastParseError",
  SUError.appcastError.rawValue: "SUAppcastError",
  SUError.runningFromDiskImageError.rawValue: "SURunningFromDiskImageError",
  SUError.resumeAppcastError.rawValue: "SUResumeAppcastError",
  SUError.runningTranslocated.rawValue: "SURunningTranslocated",
  SUError.webKitTerminationError.rawValue: "SUWebKitTerminationError",
  SUError.releaseNotesError.rawValue: "SUReleaseNotesError",
  SUError.temporaryDirectoryError.rawValue: "SUTemporaryDirectoryError",
  SUError.downloadError.rawValue: "SUDownloadError",
  SUError.unarchivingError.rawValue: "SUUnarchivingError",
  SUError.signatureError.rawValue: "SUSignatureError",
  SUError.validationError.rawValue: "SUValidationError",
  SUError.fileCopyFailure.rawValue: "SUFileCopyFailure",
  SUError.authenticationFailure.rawValue: "SUAuthenticationFailure",
  SUError.missingUpdateError.rawValue: "SUMissingUpdateError",
  SUError.missingInstallerToolError.rawValue: "SUMissingInstallerToolError",
  SUError.relaunchError.rawValue: "SURelaunchError",
  SUError.installationError.rawValue: "SUInstallationError",
  SUError.downgradeError.rawValue: "SUDowngradeError",
  SUError.installationAuthorizeLaterError.rawValue: "SUInstallationAuthorizeLaterError",
  SUError.notValidUpdateError.rawValue: "SUNotValidUpdateError",
  SUError.agentInvalidationError.rawValue: "SUAgentInvalidationError",
  SUError.installationWriteNoPermissionError.rawValue: "SUInstallationWriteNoPermissionError",
  SUError.incorrectAPIUsageError.rawValue: "SUIncorrectAPIUsageError",
  SUError.noUpdateError.rawValue: "SUNoUpdateError",
  SUError.installationCanceledError.rawValue: "SUInstallationCanceledError",
]

/// `SUError` exposes no string-name API -- this maps the stable, finite
/// enum back to its real case names, for a `platformCode` independent of
/// Swift's own runtime description format.
func sparkleErrorCaseName(_ code: OSStatus) -> String {
  sparkleErrorNamesByCode[code] ?? "SUUnknownError(\(code))"
}

/// Looks up a named `SUError` by its real case name, for scenarios that
/// want a specific, mapped failure. A name outside this table (or a raw
/// code passed directly) exercises `mapSparkleError`'s `unknown` fallback.
func sparkleErrorCode(named name: String) -> OSStatus? {
  sparkleErrorNamesByCode.first { $0.value == name }?.key
}
