import Foundation
import Sparkle

/// Owns Sparkle's updater entirely. Implements `SPUUserDriver` itself,
/// headlessly, rather than being a passive `SPUUpdaterDelegate`-only
/// observer -- the latter loses byte-level progress and checking signals.
@MainActor
final class SparkleUpdaterAdapter: NSObject {
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
    Task { await hydrateLastErrorFromBufferedFacts() }
  }

  func setFeedURL(_ url: String) {
    feedURLOverride = url
  }

  private func setState(_ newState: AdapterState) {
    state = newState
    Task { await bufferedFactsStore.recordAdapterState(newState) }
    for listener in onStateChangeListeners { listener(newState) }
  }

  func checkForUpdates() {
    updater.checkForUpdates()
  }

  /// Records an internal defect and no-ops if nothing is `available` yet
  /// -- the host is expected to gate this itself, so reaching here means
  /// the host's own pre-action check was bypassed.
  func downloadUpdate() {
    guard let reply = pendingUpdateReply else {
      InternalDefects.record("adapter:download-before-available")
      return
    }
    reply(.install)
    pendingUpdateReply = nil
  }

  /// Records an internal defect and no-ops if nothing has `downloaded`
  /// yet -- the host is expected to gate this itself, so reaching here
  /// means the host's own pre-action check was bypassed.
  func quitAndInstall() {
    guard let reply = pendingInstallReply else {
      InternalDefects.record("adapter:install-before-downloaded")
      return
    }
    reply(.install)
    pendingInstallReply = nil
  }

  func getAdapterState() -> AdapterState { state }
  func getLastUpdateError() -> UpdateFailure? { lastError }

  /// Host-control registers its own listener here; `BarrelKit.onStateChange`
  /// registers the host app's, so this must support more than one.
  func onStateChange(_ listener: @escaping (AdapterState) -> Void) {
    onStateChangeListeners.append(listener)
  }

  /// Fills `lastError` from the most recent buffered `updateError` fact on a
  /// fresh process start, before a check-in has run -- otherwise a crash
  /// right after a failure would make `getLastUpdateError()` look clean.
  private func hydrateLastErrorFromBufferedFacts() async {
    guard lastError == nil else { return }
    let mostRecent = await bufferedFactsStore.snapshot().compactMap { fact -> (UpdateFailure, String)? in
      guard case .updateError(let failure, _, let lastObservedAt, _) = fact else { return nil }
      return (failure, lastObservedAt)
    }.max { $0.1 < $1.1 }?.0
    guard let mostRecent else { return }
    // Recompute `title`, same as `buildFailureState` does, rather than
    // trusting whatever the buffered fact happened to carry.
    lastError = UpdateFailure(
      phase: mostRecent.phase, failureMode: mostRecent.failureMode,
      title: resolveFailureTitle(mostRecent.failureMode), platform: mostRecent.platform,
      platformCode: mostRecent.platformCode)
  }
}

extension SparkleUpdaterAdapter: SPUUpdaterDelegate {
  func feedURLString(for updater: SPUUpdater) -> String? {
    feedURLOverride
  }
}

extension SparkleUpdaterAdapter: SPUUserDriver {
  func show(
    _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    // Full-wrap: this SDK's own cadence drives every check explicitly --
    // there is no separate "ask permission to auto-check" UX to show.
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    setState(.checking)
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    pendingUpdateReply = reply
    setState(.available(releaseNotes: appcastItem.itemDescription))
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
    recordFailure(error)
  }

  /// Sparkle delivers this with a generic `SUNoUpdateError`, but its
  /// `userInfo` reason can mean the host can never take an update that
  /// exists -- a genuine failure; every other reason stays idle.
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    if let rawReason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? Int,
      let reason = SPUNoUpdateFoundReason(rawValue: OSStatus(rawReason)),
      let (phase, failureMode) = mapSparkleNoUpdateFoundReason(reason) {
      applyFailure(phase: phase, failureMode: failureMode, platformCode: noUpdateFoundReasonCaseName(reason))
      acknowledgement()
      return
    }
    setState(.idle)
    acknowledgement()
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    recordFailure(error)
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    setState(.downloading(progress: nil))
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    // Stored fields can't live in this extension, so this and the next
    // method route through the class's own stateful helpers below.
    setExpectedContentLength(expectedContentLength)
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    accumulateReceivedContentLength(length)
  }

  func showDownloadDidStartExtractingUpdate() {}

  /// Extraction has no separate `AdapterState` bucket -- state stays
  /// `.downloading` with whatever progress download already left in
  /// place; this callback's own `progress` argument is never used.
  func showExtractionReceivedProgress(_ progress: Double) {}

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    pendingInstallReply = reply
    setState(.downloaded)
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void
  ) {}

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showUpdateInFocus() {}

  func dismissUpdateInstallation() {
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
    applyFailure(phase: phase, failureMode: failureMode, platformCode: sparkleErrorCaseName(code))
  }

  /// Shared tail end of classifying any Sparkle failure, regardless of
  /// which callback surfaced it -- builds the failure, buffers it, and
  /// transitions `state`.
  fileprivate func applyFailure(phase: Phase, failureMode: UpdateFailureMode, platformCode: String) {
    let (failure, failedState) = buildFailureState(
      platform: "sparkle", failureMode: failureMode, phase: phase, platformCode: platformCode)
    lastError = failure
    Task { await bufferedFactsStore.recordUpdateError(failure) }
    setState(failedState)
  }
}
