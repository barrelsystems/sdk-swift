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
    // SUNoUpdateError and SUInstallationCanceledError must be special-cased by
    // the caller before reaching this function -- this only guards that if
    // one slips through, it doesn't silently resolve to a plausible-looking
    // failure, masking the missing special case.
    #expect(mapSparkleError(SUError.noUpdateError.rawValue).failureMode == .unknown)
    #expect(mapSparkleError(SUError.installationCanceledError.rawValue).failureMode == .unknown)
  }
}
