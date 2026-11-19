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
