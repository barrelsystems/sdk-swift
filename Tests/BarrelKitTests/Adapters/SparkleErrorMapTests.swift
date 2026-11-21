import Sparkle
import Testing

@testable import BarrelKit

@Suite struct SparkleErrorMapTests {
  @Test func mapsSignatureMissingErrorsToVerify() {
    for code in [SUError.noPublicDSAFoundError, .insufficientSigningError] {
      let (phase, mode) = mapSparkleError(code.rawValue)
      #expect(phase == .verify)
      #expect(mode == .signatureMissing)
    }
  }

  @Test func mapsSignatureInvalidErrorsToVerify() {
    for code in [SUError.signatureError, .validationError] {
      let (phase, mode) = mapSparkleError(code.rawValue)
      #expect(phase == .verify)
      #expect(mode == .signatureInvalid)
    }
  }

  @Test func mapsConfigurationErrorsToConfigInvalid() {
    for code in [
      SUError.insecureFeedURLError, .invalidFeedURLError, .invalidUpdaterError,
      .invalidHostBundleIdentifierError, .incorrectAPIUsageError, .runningFromDiskImageError,
    ] {
      let (phase, mode) = mapSparkleError(code.rawValue)
      #expect(phase == .config)
      #expect(mode == .configInvalid)
    }
  }

  @Test func mapsInvalidHostVersionToPlatformUnsupported() {
    let (phase, mode) = mapSparkleError(SUError.invalidHostVersionError.rawValue)
    #expect(phase == .config)
    #expect(mode == .platformUnsupported)
  }

  @Test func mapsRunningTranslocatedToTranslocationBlocked() {
    let (phase, mode) = mapSparkleError(SUError.runningTranslocated.rawValue)
    #expect(phase == .config)
    #expect(mode == .translocationBlocked)
  }

  @Test func mapsAppcastParseErrorToManifestParseFailed() {
    let (phase, mode) = mapSparkleError(SUError.appcastParseError.rawValue)
    #expect(phase == .check)
    #expect(mode == .manifestParseFailed)
  }

  @Test func mapsInstallMissingUpdateErrorsToInstall() {
    for code in [SUError.missingUpdateError, .missingInstallerToolError, .notValidUpdateError] {
      let (phase, mode) = mapSparkleError(code.rawValue)
      #expect(phase == .install)
      #expect(mode == .installMissingUpdate)
    }
  }

  @Test func mapsRelaunchErrorsToInstallRelaunchFailed() {
    for code in [SUError.relaunchError, .agentInvalidationError] {
      let (phase, mode) = mapSparkleError(code.rawValue)
      #expect(phase == .install)
      #expect(mode == .installRelaunchFailed)
    }
  }

  @Test func mapsInstallationErrorToUnknown() {
    let (phase, mode) = mapSparkleError(SUError.installationError.rawValue)
    #expect(phase == .install)
    #expect(mode == .unknown)
  }

  @Test func mapsAnUnrecognizedCodeToUnknown() {
    let (phase, mode) = mapSparkleError(999_999)
    #expect(phase == .unknown)
    #expect(mode == .unknown)
  }

  @Test func neverMapsTheTwoNonFailureCodes() {
    // SUNoUpdateError/SUInstallationCanceledError must be special-cased by
    // the caller before reaching this function -- this only guards that a
    // slipped-through code doesn't silently resolve to a plausible failure.
    #expect(mapSparkleError(SUError.noUpdateError.rawValue).failureMode == .unknown)
    #expect(mapSparkleError(SUError.installationCanceledError.rawValue).failureMode == .unknown)
  }

  @Test func mapsUnreachableNoUpdateFoundReasonsToPlatformUnsupported() {
    for reason: SPUNoUpdateFoundReason in [.systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64] {
      let mapped = mapSparkleNoUpdateFoundReason(reason)
      #expect(mapped?.phase == .config)
      #expect(mapped?.failureMode == .platformUnsupported)
    }
  }

  @Test func mapsGenuinelyCurrentNoUpdateFoundReasonsToNil() {
    // These mean "you're already current", not a failure -- the caller
    // must keep treating them as a no-op idle transition.
    for reason: SPUNoUpdateFoundReason in [.onLatestVersion, .onNewerThanLatestVersion] {
      #expect(mapSparkleNoUpdateFoundReason(reason) == nil)
    }
  }

  @Test func mapsUnknownNoUpdateFoundReasonToNilWithoutClaimingCurrency() {
    // Sparkle attached no reason -- this falls back to idle like the
    // genuinely-current cases above, but it is not itself evidence of currency.
    #expect(mapSparkleNoUpdateFoundReason(.unknown) == nil)
  }

  @Test func knownSparkleErrorCaseCountMatchesSUErrorsH() {
    // SUError is an NS_ENUM import, so the compiler enforces no
    // switch-exhaustiveness over it -- a version bump adding a case
    // compiles silently and needs this count to catch the drift.
    let knownSUErrorCaseCount = 33
    #expect(knownSparkleErrorCaseCount() == knownSUErrorCaseCount)
  }

  @Test func mapSparkleErrorHandlesEveryKnownCodeExplicitly() {
    // `mapSparkleError`'s `default` arm is the only one returning phase
    // `.unknown`; a code present in `sparkleErrorNamesByCode` but missing
    // its own switch arm would silently fall through to it instead.
    let specialCased: Set<OSStatus> = [
      SUError.noUpdateError.rawValue, SUError.installationCanceledError.rawValue,
    ]
    for code in knownSparkleErrorCodes() where !specialCased.contains(code) {
      #expect(mapSparkleError(code).phase != .unknown)
    }
  }
}
