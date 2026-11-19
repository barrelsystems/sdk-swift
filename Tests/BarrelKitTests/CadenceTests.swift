import Foundation
import Testing

@testable import BarrelKit

@Suite struct CadenceTests {
  @Test func aHeldPolicyWithinCeilingHoldsTheVendorCheck() {
    let policy = Policy.held(
      issuedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
      environment: "production", reason: nil, until: nil)
    #expect(policyHoldsTheVendorCheck(policy, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func noPolicyYetDoesNotHoldTheVendorCheck() {
    #expect(!policyHoldsTheVendorCheck(nil, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func aCurrentPolicyDoesNotHoldTheVendorCheck() {
    let policy = Policy.current(issuedAt: ISO8601DateFormatter().string(from: Date()), environment: "production")
    #expect(!policyHoldsTheVendorCheck(policy, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func anUpdateEligiblePolicyDoesNotHoldTheVendorCheck() {
    let policy = Policy.updateEligible(
      issuedAt: ISO8601DateFormatter().string(from: Date()), environment: "production", priority: nil)
    #expect(!policyHoldsTheVendorCheck(policy, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func aHeldPolicyOlderThanHoldCacheMaxAgeFailsOpen() {
    let policy = Policy.held(
      issuedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 60 * 60)),
      environment: "production", reason: nil, until: nil)
    #expect(!policyHoldsTheVendorCheck(policy, holdCacheMaxAge: 60 * 60))
  }

  @Test func aHeldPolicyPastItsOwnUntilFailsOpenEvenUnderHoldCacheMaxAge() {
    let policy = Policy.held(
      issuedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
      environment: "production", reason: nil,
      until: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30)))
    #expect(!policyHoldsTheVendorCheck(policy, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func aHeldPolicyBeforeItsOwnUntilHoldsTheVendorCheck() {
    let policy = Policy.held(
      issuedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
      environment: "production", reason: nil,
      until: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)))
    #expect(policyHoldsTheVendorCheck(policy, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test @MainActor func initializeThrowsSynchronouslyWhenHoldCacheMaxAgeExceedsSevenDays() {
    let config = InitConfig(credential: "cred", holdCacheMaxAge: 8 * 24 * 60 * 60)
    #expect(throws: BarrelConfigError.self) {
      try BarrelKit.shared.initialize(config)
    }
  }
}
