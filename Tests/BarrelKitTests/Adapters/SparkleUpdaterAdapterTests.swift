import Sparkle
import Testing

@testable import BarrelKit

@Suite struct SparkleUpdaterAdapterTests {
  @Test @MainActor func onStateChangeNotifiesEveryRegisteredListener() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    var first: [Updates.State] = []
    var second: [Updates.State] = []
    adapter.onStateChange { first.append($0) }
    adapter.onStateChange { second.append($0) }

    adapter.showUserInitiatedUpdateCheck(cancellation: {})

    #expect(first == [.checking])
    #expect(second == [.checking])
  }

  // Drive a reportable native transition through the adapter, so buffer
  // coverage cannot pass with an unwired persistence store.
  @Test @MainActor func aStateTransitionLandsInTheBufferedFactsStore() async {
    let store = BufferedFactsStore()
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: store)

    adapter.showDownloadInitiated(cancellation: {})

    var facts: [BufferedFact] = []
    for _ in 0..<50 {
      facts = await store.snapshot()
      if !facts.isEmpty { break }
      await Task.yield()
    }

    #expect(facts.count == 1)
    guard case .lifecycleState(let state, _, _, let occurrenceCount, _) = facts.first else {
      Issue.record("expected an .lifecycleState fact, got \(String(describing: facts.first))")
      return
    }
    #expect(state == .downloading(progress: nil))
    #expect(occurrenceCount == 1)
  }

  // `.checking` is SDK activity, not an application state -- it must never
  // reach the backend, as a buffered fact or otherwise.
  @Test @MainActor func checkingNeverLandsInTheBufferedFactsStore() async {
    let store = BufferedFactsStore()
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: store)

    adapter.showUserInitiatedUpdateCheck(cancellation: {})
    await Task.yield()

    #expect(await store.snapshot().isEmpty)
    #expect(adapter.getUpdateState() == .checking)
    #expect(adapter.getReportableUpdateState() == .idle)
  }

  // Marking applying must leave room for HostControl to await its sync
  // before invoking the native Sparkle install reply.
  @Test @MainActor func markApplyingTransitionsStateSynchronously() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())

    var observed: Updates.State?
    adapter.onStateChange { observed = $0 }
    adapter.markApplying()

    #expect(observed == .applying)
    #expect(adapter.getUpdateState() == .applying)
    #expect(adapter.getReportableUpdateState() == .applying)
  }

  // `onUpdateError` fires exactly once per newly-recorded failure, in
  // addition to -- never instead of -- `getLastUpdateError()`'s own polling.
  @Test @MainActor func onUpdateErrorNotifiesEveryRegisteredListenerExactlyOncePerFailure() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    var first: [Updates.Failure] = []
    var second: [Updates.Failure] = []
    adapter.onUpdateError { first.append($0) }
    adapter.onUpdateError { second.append($0) }

    let error = NSError(
      domain: "SUSparkleErrorDomain", code: Int(SUError.releaseNotesError.rawValue))
    adapter.showUpdateReleaseNotesFailedToDownloadWithError(error)

    #expect(first.count == 1)
    #expect(second.count == 1)
    #expect(first.first == adapter.getLastUpdateError())
  }

  @Test @MainActor func quitAndInstallIssuesTheReplyWithoutChangingState() {
    var reportedChoice: SPUUserUpdateChoice?
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    adapter.showReady(toInstallAndRelaunch: { choice in reportedChoice = choice })
    adapter.markApplying()

    adapter.quitAndInstall()

    #expect(reportedChoice == .install)
    #expect(adapter.getUpdateState() == .applying)
  }

  @Test @MainActor func downloadUpdateBeforeAvailableRecordsAnInternalDefectInsteadOfCrashing() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let before = InternalDefects.counts(for: "adapter:download-before-available")

    adapter.downloadUpdate()

    #expect(InternalDefects.counts(for: "adapter:download-before-available") == before + 1)
  }

  @Test @MainActor func quitAndInstallBeforeDownloadedRecordsAnInternalDefectInsteadOfCrashing() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let before = InternalDefects.counts(for: "adapter:install-before-downloaded")

    adapter.quitAndInstall()

    #expect(InternalDefects.counts(for: "adapter:install-before-downloaded") == before + 1)
  }

  // Spec: a fresh process start (e.g. after a crash) must still be able to
  // answer `getLastUpdateError()` from the buffered-fact store, not just
  // from an in-memory `lastError` that a real check-in hasn't set yet.
  @Test @MainActor func getLastUpdateErrorFallsBackToTheMostRecentBufferedUpdateErrorFact() async {
    let store = BufferedFactsStore()
    await store.recordUpdateError(
      Updates.Failure(
        phase: .download, failureMode: .downloadTransportFailed, title: "stale title",
        platform: "sparkle", platformCode: "SUDownloadError"))
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: store)

    await adapter.hydrateLastErrorFromBufferedFacts()
    let lastError = adapter.getLastUpdateError()

    #expect(lastError?.phase == .download)
    #expect(lastError?.failureMode == .downloadTransportFailed)
    #expect(lastError?.platformCode == "SUDownloadError")
    #expect(lastError?.title == resolveFailureTitle(.downloadTransportFailed))
  }

  // Spec: extraction has no separate `Updates.State` bucket -- the state
  // stays `.downloading` and its `progress` is never repurposed for the
  // extraction callback's own progress argument.
  @Test @MainActor func showExtractionReceivedProgressDoesNotOverwriteAnAlreadySetDownloadProgress()
  {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    adapter.showDownloadDidReceiveExpectedContentLength(100)
    adapter.showDownloadDidReceiveData(ofLength: 40)

    adapter.showExtractionReceivedProgress(0.9)

    #expect(adapter.getUpdateState() == .downloading(progress: 40))
  }

  // Spec: Sparkle delivers a release-notes-download failure via this
  // dedicated callback, not via `showUpdaterError` -- it must still reach
  // the adapter's own error-recording path.
  @Test @MainActor func showUpdateReleaseNotesFailedToDownloadWithErrorRecordsAReleaseNotesFailure()
  {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let error = NSError(
      domain: "SUSparkleErrorDomain", code: Int(SUError.releaseNotesError.rawValue))

    adapter.showUpdateReleaseNotesFailedToDownloadWithError(error)

    let failure = adapter.getLastUpdateError()
    #expect(failure?.phase == .check)
    #expect(failure?.failureMode == .releaseNotesFailed)
    #expect(failure?.platformCode == "SUReleaseNotesError")
  }

  // Spec: Sparkle reports "no update found" with the generic SUNoUpdateError
  // for every reason, but a host too old/new/unsupported for the found
  // update is a real failure -- classified from SPUNoUpdateFoundReasonKey.
  @Test @MainActor
  func showUpdateNotFoundWithErrorRecordsAFailureWhenTheHostCannotTakeTheFoundUpdate() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    // Sparkle itself boxes the reason as `@(reason)` (an NSNumber) -- mirror
    // that here rather than a bare Int32, which doesn't bridge the same way.
    let error = NSError(
      domain: "SUSparkleErrorDomain", code: Int(SUError.noUpdateError.rawValue),
      userInfo: [
        SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.systemIsTooOld.rawValue)
      ])

    adapter.showUpdateNotFoundWithError(error, acknowledgement: {})

    let failure = adapter.getLastUpdateError()
    #expect(failure?.phase == .config)
    #expect(failure?.failureMode == .platformUnsupported)
    #expect(failure?.platformCode == "SPUNoUpdateFoundReasonSystemIsTooOld")
    #expect(
      adapter.getUpdateState()
        == .failed(
          category: .updater, code: .platformUnsupported,
          platformCode: "SPUNoUpdateFoundReasonSystemIsTooOld"))
  }

  // Spec: the ordinary "you're already current" reasons stay a no-op --
  // this must not regress into treating every no-update-found as a failure.
  @Test @MainActor func showUpdateNotFoundWithErrorStaysIdleWhenGenuinelyCurrent() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let error = NSError(
      domain: "SUSparkleErrorDomain", code: Int(SUError.noUpdateError.rawValue),
      userInfo: [
        SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)
      ])

    adapter.showUpdateNotFoundWithError(error, acknowledgement: {})

    #expect(adapter.getUpdateState() == .idle)
    #expect(adapter.getLastUpdateError() == nil)
  }

  // Spec: an error with no reason key at all (or an unrecognized one) must
  // fall back to idle rather than crashing or misclassifying.
  @Test @MainActor func showUpdateNotFoundWithErrorStaysIdleWhenNoReasonIsPresent() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let error = NSError(domain: "SUSparkleErrorDomain", code: Int(SUError.noUpdateError.rawValue))

    adapter.showUpdateNotFoundWithError(error, acknowledgement: {})

    #expect(adapter.getUpdateState() == .idle)
    #expect(adapter.getLastUpdateError() == nil)
  }
  @Test @MainActor func checkingCannotReplaceAnUpdateAlreadyReadyToApply() {
    var checks = 0
    let adapter = SparkleUpdaterAdapter(
      hostBundle: .main, bufferedFactsStore: BufferedFactsStore(), checkForUpdates: { checks += 1 })
    adapter.showReady(toInstallAndRelaunch: { _ in })
    adapter.checkForUpdates()
    #expect(checks == 0)
    #expect(adapter.getUpdateState() == .downloaded)
  }

}
