import Sparkle
import Testing

@testable import BarrelKit

@Suite struct SparkleMappingContractTests {
  @Test @MainActor func everyFailureCodeReachesThePublicErrorAndFailedState() {
    let cases: [(SUError, Updates.Phase, Updates.FailureMode, String)] = [
      (.noPublicDSAFoundError, .verify, .signatureMissing, "SUNoPublicDSAFoundError"),
      (.insufficientSigningError, .verify, .signatureMissing, "SUInsufficientSigningError"),
      (.signatureError, .verify, .signatureInvalid, "SUSignatureError"),
      (.validationError, .verify, .signatureInvalid, "SUValidationError"),
      (.insecureFeedURLError, .config, .configInvalid, "SUInsecureFeedURLError"),
      (.invalidFeedURLError, .config, .configInvalid, "SUInvalidFeedURLError"),
      (.invalidUpdaterError, .config, .configInvalid, "SUInvalidUpdaterError"),
      (
        .invalidHostBundleIdentifierError, .config, .configInvalid,
        "SUInvalidHostBundleIdentifierError"
      ),
      (.incorrectAPIUsageError, .config, .configInvalid, "SUIncorrectAPIUsageError"),
      (.runningFromDiskImageError, .config, .configInvalid, "SURunningFromDiskImageError"),
      (.invalidHostVersionError, .config, .platformUnsupported, "SUInvalidHostVersionError"),
      (.runningTranslocated, .config, .translocationBlocked, "SURunningTranslocated"),
      (.appcastParseError, .check, .manifestParseFailed, "SUAppcastParseError"),
      (.appcastError, .check, .manifestUnreachable, "SUAppcastError"),
      (.resumeAppcastError, .check, .resumeAppcastFailed, "SUResumeAppcastError"),
      (.webKitTerminationError, .check, .webkitTerminated, "SUWebKitTerminationError"),
      (.releaseNotesError, .check, .releaseNotesFailed, "SUReleaseNotesError"),
      (.temporaryDirectoryError, .download, .tempStorageConstraint, "SUTemporaryDirectoryError"),
      (.downloadError, .download, .downloadTransportFailed, "SUDownloadError"),
      (.unarchivingError, .extract, .extractionFailed, "SUUnarchivingError"),
      (.fileCopyFailure, .install, .installWriteFailed, "SUFileCopyFailure"),
      (
        .installationWriteNoPermissionError, .install, .installWriteFailed,
        "SUInstallationWriteNoPermissionError"
      ),
      (.authenticationFailure, .install, .installAuthRequiredOrFailed, "SUAuthenticationFailure"),
      (
        .installationAuthorizeLaterError, .install, .installAuthRequiredOrFailed,
        "SUInstallationAuthorizeLaterError"
      ),
      (.missingUpdateError, .install, .installMissingUpdate, "SUMissingUpdateError"),
      (.missingInstallerToolError, .install, .installMissingUpdate, "SUMissingInstallerToolError"),
      (.notValidUpdateError, .install, .installMissingUpdate, "SUNotValidUpdateError"),
      (.relaunchError, .install, .installRelaunchFailed, "SURelaunchError"),
      (.agentInvalidationError, .install, .installRelaunchFailed, "SUAgentInvalidationError"),
      (.installationError, .install, .unknown, "SUInstallationError"),
      (.downgradeError, .install, .installDowngradeBlocked, "SUDowngradeError"),
    ]
    #expect(cases.count == 31)
    #expect(Set(cases.map { $0.0.rawValue }).count == cases.count)

    for (code, phase, mode, platformCode) in cases {
      let adapter = SparkleUpdaterAdapter(
        hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
      #expect(adapter.getLastUpdateError() == nil)
      var acknowledgements = 0

      adapter.showUpdaterError(
        NSError(domain: "SUSparkleErrorDomain", code: Int(code.rawValue)),
        acknowledgement: { acknowledgements += 1 })

      let failure = adapter.getLastUpdateError()
      #expect(failure?.phase == phase)
      #expect(failure?.failureMode == mode)
      #expect(failure?.platform == "sparkle")
      #expect(failure?.platformCode == platformCode)
      #expect(failure?.title == resolveFailureTitle(mode))
      #expect(
        adapter.getUpdateState()
          == .failed(
            category: category(forPhase: phase), code: mode, platformCode: platformCode))
      #expect(acknowledgements == 1)

      adapter.showUserInitiatedUpdateCheck(cancellation: {})
      #expect(adapter.getLastUpdateError() == failure)
    }
  }

  @Test @MainActor func cancellationAndNoUpdateAreNotFailures() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    for (code, expected): (SUError, Updates.State) in [
      (.installationCanceledError, .updateCancelled), (.noUpdateError, .idle),
    ] {
      adapter.showUpdaterError(
        NSError(domain: "SUSparkleErrorDomain", code: Int(code.rawValue)), acknowledgement: {})

      #expect(adapter.getUpdateState() == expected)
      #expect(adapter.getLastUpdateError() == nil)
    }
  }

  @Test @MainActor func unknownErrorsRetainTheRawCodeAndPlatform() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    adapter.showUpdaterError(
      NSError(domain: "SUSparkleErrorDomain", code: 999_999), acknowledgement: {})

    let failure = adapter.getLastUpdateError()
    #expect(failure?.failureMode == .unknown)
    #expect(failure?.phase == .unknown)
    #expect(failure?.platform == "sparkle")
    #expect(failure?.platformCode == "SUUnknownError(999999)")
  }

  @Test @MainActor func delegateOnlyAbortReportsCancellationAndFailure() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let updater = SPUUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: adapter, delegate: adapter)
    adapter.updater(
      updater,
      didAbortWithError: NSError(
        domain: "SUSparkleErrorDomain", code: Int(SUError.installationCanceledError.rawValue)))
    #expect(adapter.getUpdateState() == .updateCancelled)
    #expect(adapter.getLastUpdateError() == nil)

    adapter.updater(
      updater,
      didAbortWithError: NSError(
        domain: "SUSparkleErrorDomain", code: Int(SUError.downloadError.rawValue)))
    #expect(adapter.getLastUpdateError()?.failureMode == .downloadTransportFailed)
    #expect(
      adapter.getUpdateState()
        == .failed(
          category: .download, code: .downloadTransportFailed, platformCode: "SUDownloadError"))
  }

  @Test @MainActor func driverAndDelegateCallbacksCountOneFailureOnce() async {
    let store = BufferedFactsStore()
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: store)
    let updater = SPUUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: adapter, delegate: adapter)
    let error = NSError(domain: "SUSparkleErrorDomain", code: Int(SUError.downloadError.rawValue))
    var states: [Updates.State] = []
    adapter.onStateChange { states.append($0) }

    adapter.showUpdaterError(error, acknowledgement: {})
    adapter.updater(updater, didAbortWithError: error)
    #expect(states.count == 1)

    for _ in 0..<100 {
      let facts = await store.snapshot()
      if facts.count >= 2 {
        let counts = facts.compactMap { fact -> Int? in
          guard case .updateError(_, _, _, let count, _) = fact else { return nil }
          return count
        }
        #expect(counts == [1])
        return
      }
      await Task.yield()
    }
    Issue.record("failure was not buffered")
  }

  @Test @MainActor func lifecycleCallbacksPreserveDownloadProgressDuringExtraction() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    adapter.showUserInitiatedUpdateCheck(cancellation: {})
    #expect(adapter.getUpdateState() == .checking)

    adapter.handleUpdateFound(version: "2.0.0", releaseNotes: "Changes", reply: { _ in })
    #expect(adapter.getUpdateState() == .available(releaseNotes: "Changes"))
    #expect(adapter.getTargetVersion() == "2.0.0")

    adapter.showDownloadInitiated(cancellation: {})
    #expect(adapter.getUpdateState() == .downloading(progress: nil))
    adapter.showDownloadDidReceiveData(ofLength: 20)
    #expect(adapter.getUpdateState() == .downloading(progress: nil))

    adapter.showDownloadDidReceiveExpectedContentLength(200)
    adapter.showDownloadDidReceiveData(ofLength: 40)
    adapter.showDownloadDidReceiveData(ofLength: 61)
    #expect(adapter.getUpdateState() == .downloading(progress: 51))

    adapter.showDownloadDidStartExtractingUpdate()
    adapter.showExtractionReceivedProgress(0.99)
    #expect(adapter.getUpdateState() == .downloading(progress: 51))

    adapter.showDownloadDidReceiveData(ofLength: 200)
    #expect(adapter.getUpdateState() == .downloading(progress: 100))
    adapter.showReady(toInstallAndRelaunch: { _ in })
    #expect(adapter.getUpdateState() == .downloaded)
    #expect(adapter.getLastUpdateError() == nil)

    adapter.showDownloadInitiated(cancellation: {})
    adapter.showDownloadDidReceiveData(ofLength: 1)
    #expect(adapter.getUpdateState() == .downloading(progress: nil))
  }
}
