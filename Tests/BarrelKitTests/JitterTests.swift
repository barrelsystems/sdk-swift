import Testing

@testable import BarrelKit

@Suite struct JitterTests {
  @Test func staysWithinTenToFifteenPercent() {
    for id in ["a", "installation-123", "zzzzzzzz", "", "non-ascii-🎯"] {
      let fraction = computeJitterFraction(installationId: id)
      #expect(abs(fraction) >= 0.1)
      #expect(abs(fraction) <= 0.15)
    }
  }

  @Test func isDeterministicForTheSameInstallationId() {
    let id = "same-installation"
    #expect(computeJitterFraction(installationId: id) == computeJitterFraction(installationId: id))
  }

  @Test func variesAcrossDifferentInstallationIds() {
    let fractions = Set(["a", "b", "c", "d"].map { computeJitterFraction(installationId: $0) })
    #expect(fractions.count > 1)
  }
}
