import Testing

@testable import BarrelKit

@Suite struct ErrorTaxonomyTests {
  @Test(arguments: [
    UpdateFailureMode.manifestUnreachable, .manifestParseFailed, .versionInvalid, .signatureMissing,
    .signatureInvalid, .signatureVersionMismatch, .downloadTransportFailed,
    .extractionFailed, .tempStorageConstraint, .installWriteFailed,
    .installAuthRequiredOrFailed, .installDowngradeBlocked, .installRelaunchFailed, .installMissingUpdate,
    .configInvalid, .platformUnsupported, .translocationBlocked,
    .webkitTerminated, .releaseNotesFailed, .resumeAppcastFailed, .unknown,
  ])
  func resolvesANonEmptyTitleForEveryMode(_ mode: UpdateFailureMode) {
    #expect(!resolveFailureTitle(mode).isEmpty)
  }

  @Test func mapsCheckToCheck() {
    #expect(category(forPhase: .check) == .check)
  }

  @Test func mapsVerifyDownloadAndExtractToDownload() {
    #expect(category(forPhase: .verify) == .download)
    #expect(category(forPhase: .download) == .download)
    #expect(category(forPhase: .extract) == .download)
  }

  @Test func mapsInstallConfigAndUnknownToUpdater() {
    #expect(category(forPhase: .install) == .updater)
    #expect(category(forPhase: .config) == .updater)
    #expect(category(forPhase: .unknown) == .updater)
  }
}
