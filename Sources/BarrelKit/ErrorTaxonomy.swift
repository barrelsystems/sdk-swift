private let failureModeTitles: [UpdateFailureMode: String] = [
  .manifestUnreachable: "Could not reach the update manifest.",
  .manifestParseFailed: "The update manifest could not be parsed.",
  .versionInvalid: "The update manifest's version is invalid.",
  .signatureMissing: "The update manifest has no signature.",
  .signatureInvalid: "The update manifest's signature is invalid.",
  .signatureVersionMismatch: "The update's signed version doesn't match the manifest.",
  .downloadTransportFailed: "The update download failed at the network layer.",
  .extractionFailed: "The downloaded update could not be extracted.",
  .tempStorageConstraint: "A temporary-storage constraint blocked the update.",
  .installWriteFailed: "The update could not be written to disk.",
  .installAuthRequiredOrFailed: "The update install needs or failed authorization.",
  .installDowngradeBlocked: "The update was blocked as a version downgrade.",
  .installRelaunchFailed: "The app could not relaunch after installing the update.",
  .installMissingUpdate: "The downloaded update file is missing at install time.",
  .configInvalid: "The updater's configuration is invalid.",
  .platformUnsupported: "This update isn't supported on the current platform.",
  .translocationBlocked: "macOS App Translocation blocked the update.",
  .webkitTerminated: "The updater's WebKit process terminated unexpectedly.",
  .releaseNotesFailed: "The update's release notes could not be loaded.",
  .resumeAppcastFailed: "Resuming the update feed after a prior failure didn't work.",
  .applyNotConfirmed: "The app quit to apply an update, but never came back up on the new version.",
  .unknown: "An unclassified update failure occurred.",
]

/// `title` is resolved here, at return/display time -- never persisted or transmitted.
func resolveFailureTitle(_ failureMode: UpdateFailureMode) -> String {
  failureModeTitles[failureMode] ?? "An unclassified update failure occurred."
}

/// Mechanical, fixed derivation -- never a second independent classification.
func category(forPhase phase: Phase) -> AdapterState.FailureCategory {
  switch phase {
  case .check: return .check
  case .verify, .download, .extract: return .download
  default: return .updater
  }
}

/// Builds the matching `UpdateFailure` and `AdapterState.failed` from one classification.
func buildFailureState(platform: String, failureMode: UpdateFailureMode, phase: Phase, platformCode: String) -> (
  failure: UpdateFailure, state: AdapterState
) {
  let failure = UpdateFailure(
    phase: phase, failureMode: failureMode, title: resolveFailureTitle(failureMode), platform: platform,
    platformCode: platformCode)
  let state = AdapterState.failed(category: category(forPhase: phase), code: failureMode, platformCode: platformCode)
  return (failure, state)
}
