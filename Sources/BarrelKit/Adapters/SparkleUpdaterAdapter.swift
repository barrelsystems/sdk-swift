import Foundation
import Sparkle

/// Owns Sparkle's updater entirely. Implements `SPUUserDriver` itself,
/// headlessly, rather than being a passive `SPUUpdaterDelegate`-only
/// observer -- the latter loses byte-level progress and checking signals.
@MainActor
public final class SparkleUpdaterAdapter: NSObject {
  private var updater: SPUUpdater!
  private var feedURLOverride: String?
  private let bufferedFactsStore: BufferedFactsStore

  private var state: AdapterState = .idle
  private var lastError: UpdateFailure?
  private var onStateChangeListeners: [(AdapterState) -> Void] = []

  // Stored replies: full-wrap means the host's own pre-action-check gates
  // *when* these fire, not Sparkle's own automatic timing.
  private var pendingUpdateReply: ((SPUUserUpdateChoice) -> Void)?
  private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?

  // Sparkle gives bytes, never a percentage -- accumulated here to derive one.
  private var expectedContentLength: UInt64 = 0
  private var receivedContentLength: UInt64 = 0

  init(hostBundle: Bundle, bufferedFactsStore: BufferedFactsStore) {
    self.bufferedFactsStore = bufferedFactsStore
    super.init()
    updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: self, delegate: self)
    try? updater.start()
  }

  public func setFeedURL(_ url: String) {
    feedURLOverride = url
  }

  private func setState(_ newState: AdapterState) {
    state = newState
    Task { await bufferedFactsStore.recordAdapterState(newState) }
    for listener in onStateChangeListeners { listener(newState) }
  }

  // MARK: Updater adapter public surface

  public func checkForUpdates() {
    updater.checkForUpdates()
  }

  public func downloadUpdate() {
    pendingUpdateReply?(.install)
    pendingUpdateReply = nil
  }

  public func quitAndInstall() {
    pendingInstallReply?(.install)
    pendingInstallReply = nil
  }

  public func getAdapterState() -> AdapterState { state }
  public func getLastUpdateError() -> UpdateFailure? { lastError }

  /// Host-control registers its own listener here; `BarrelKit.onStateChange`
  /// registers the host app's, so this must support more than one.
  public func onStateChange(_ listener: @escaping (AdapterState) -> Void) {
    onStateChangeListeners.append(listener)
  }
}

extension SparkleUpdaterAdapter: SPUUpdaterDelegate {
  public func feedURLString(for updater: SPUUpdater) -> String? {
    feedURLOverride
  }
}

extension SparkleUpdaterAdapter: SPUUserDriver {
  public func show(
    _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    // Full-wrap: this SDK's own cadence drives every check explicitly --
    // there is no separate "ask permission to auto-check" UX to show.
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }

  public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    setState(.checking)
  }

  public func showUpdateFound(
    with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    pendingUpdateReply = reply
    setState(.available(releaseNotes: appcastItem.itemDescription))
  }

  public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

  public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

  public func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    setState(.idle)
    acknowledgement()
  }

  public func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    recordFailure(error)
    acknowledgement()
  }

  public func showDownloadInitiated(cancellation: @escaping () -> Void) {
    setState(.downloading(progress: nil))
  }

  public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    // Stored fields can't live in this extension, so this and the next
    // method route through the class's own stateful helpers below.
    setExpectedContentLength(expectedContentLength)
  }

  public func showDownloadDidReceiveData(ofLength length: UInt64) {
    accumulateReceivedContentLength(length)
  }

  public func showDownloadDidStartExtractingUpdate() {}

  public func showExtractionReceivedProgress(_ progress: Double) {
    setState(.downloading(progress: Int((progress * 100).rounded())))
  }

  public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    pendingInstallReply = reply
    setState(.downloaded)
  }

  public func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void
  ) {}

  public func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  public func showUpdateInFocus() {}

  public func dismissUpdateInstallation() {
    pendingUpdateReply = nil
    pendingInstallReply = nil
  }
}

extension SparkleUpdaterAdapter {
  fileprivate func setExpectedContentLength(_ length: UInt64) {
    expectedContentLength = length
    receivedContentLength = 0
  }

  fileprivate func accumulateReceivedContentLength(_ length: UInt64) {
    receivedContentLength += length
    guard expectedContentLength > 0 else {
      setState(.downloading(progress: nil))
      return
    }
    let progress = Int((Double(receivedContentLength) / Double(expectedContentLength) * 100).rounded())
    setState(.downloading(progress: min(progress, 100)))
  }

  fileprivate func recordFailure(_ error: Error) {
    let nsError = error as NSError
    let code = OSStatus(nsError.code)
    // Two SUError codes are routine outcomes, not failures.
    if code == SUError.noUpdateError.rawValue {
      setState(.idle)
      return
    }
    if code == SUError.installationCanceledError.rawValue {
      setState(.updateCancelled)
      return
    }

    let (phase, failureMode) = mapSparkleError(code)
    let platformCode = sparkleErrorCaseName(code)
    let (failure, failedState) = buildFailureState(
      platform: "sparkle", failureMode: failureMode, phase: phase, platformCode: platformCode)
    lastError = failure
    Task { await bufferedFactsStore.recordUpdateError(failure) }
    setState(failedState)
  }
}

/// `SUError` exposes no string-name API -- this maps the stable, finite
/// enum back to its real case names, for a `platformCode` independent of
/// Swift's own runtime description format.
private func sparkleErrorCaseName(_ code: OSStatus) -> String {
  let names: [OSStatus: String] = [
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
  ]
  return names[code] ?? "SUUnknownError(\(code))"
}
