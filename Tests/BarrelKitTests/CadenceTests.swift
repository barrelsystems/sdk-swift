import Foundation
import Testing

@testable import BarrelKit

@Suite struct CadenceTests {
  @Test(arguments: ["", "  "])
  @MainActor func rejectsBlankCredentialsSynchronously(credential: String) {
    let runtime = BarrelKit(environment: RuntimeEnvironment())

    #expect(throws: BarrelConfigError.self) {
      try runtime.initialize(InitConfig(credential: credential))
    }
    #expect(runtime.updates.adapter == nil)
  }

  @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
  @MainActor func rejectsNonFiniteIntervalsSynchronously(interval: Double) {
    let runtime = BarrelKit(environment: RuntimeEnvironment())

    #expect(throws: BarrelConfigError.self) {
      try runtime.initialize(
        InitConfig(
          credential: "cred",
          updates: Updates.Config(checkInInterval: interval)))
    }
  }

  @Test func aHeldDecisionWithinCeilingHoldsTheVendorCheck() {
    let updateEligibility = Updates.Eligibility.held(
      issuedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
      environment: "production", reason: nil, until: nil)
    #expect(updateEligibilityHoldsTheVendorCheck(updateEligibility, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func noDecisionYetDoesNotHoldTheVendorCheck() {
    #expect(!updateEligibilityHoldsTheVendorCheck(nil, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func anUnrestrictedDecisionDoesNotHoldTheVendorCheck() {
    let updateEligibility = Updates.Eligibility.unrestricted(
      issuedAt: ISO8601DateFormatter().string(from: Date()), environment: "production")
    #expect(!updateEligibilityHoldsTheVendorCheck(updateEligibility, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func anEligibleDecisionDoesNotHoldTheVendorCheck() {
    let updateEligibility = Updates.Eligibility.eligible(
      issuedAt: ISO8601DateFormatter().string(from: Date()), environment: "production",
      priority: nil)
    #expect(!updateEligibilityHoldsTheVendorCheck(updateEligibility, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func aHeldDecisionOlderThanHoldCacheMaxAgeFailsOpen() {
    let updateEligibility = Updates.Eligibility.held(
      issuedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 60 * 60)),
      environment: "production", reason: nil, until: nil)
    #expect(!updateEligibilityHoldsTheVendorCheck(updateEligibility, holdCacheMaxAge: 60 * 60))
  }

  @Test func aHeldDecisionPastItsOwnUntilFailsOpenEvenUnderHoldCacheMaxAge() {
    let updateEligibility = Updates.Eligibility.held(
      issuedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
      environment: "production", reason: nil,
      until: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30)))
    #expect(!updateEligibilityHoldsTheVendorCheck(updateEligibility, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test func aHeldDecisionBeforeItsOwnUntilHoldsTheVendorCheck() {
    let updateEligibility = Updates.Eligibility.held(
      issuedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
      environment: "production", reason: nil,
      until: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)))
    #expect(updateEligibilityHoldsTheVendorCheck(updateEligibility, holdCacheMaxAge: 24 * 60 * 60))
  }

  @Test @MainActor func initializeThrowsSynchronouslyWhenHoldCacheMaxAgeExceedsSevenDays() {
    let config = InitConfig(
      credential: "cred",
      updates: Updates.Config(holdCacheMaxAge: 8 * 24 * 60 * 60))
    #expect(throws: BarrelConfigError.self) {
      try BarrelKit.shared.initialize(config)
    }
  }
}

/// Shared stub response plumbing for every mocked check-in in this file.
/// Subclasses add only what differs -- e.g. counting requests -- via
/// `willRespond()`, instead of each re-implementing the same response.
private class StubCheckInProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  func willRespond() {}

  override func startLoading() {
    willRespond()
    let body = #"{"protocolVersion":1,"updateEligibility":"{}","signature":"sig"}"#
    guard let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class CountingCheckInProtocol: StubCheckInProtocol {
  nonisolated(unsafe) static var requestCount = 0
  override func willRespond() { Self.requestCount += 1 }
}

// Separate protocol classes isolate counters between concurrent suites.
private final class QuietCheckInProtocol: StubCheckInProtocol {}

private func mockedSession(protocolClass: URLProtocol.Type) -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [protocolClass]
  return URLSession(configuration: config)
}

private func countingSession() -> URLSession {
  mockedSession(protocolClass: CountingCheckInProtocol.self)
}
private func quietSession() -> URLSession {
  mockedSession(protocolClass: QuietCheckInProtocol.self)
}

private struct TestCadenceOptions {
  var checkInInterval: TimeInterval = minIntervalSeconds
  var debounceSeconds: TimeInterval = defaultStateSyncDebounceSeconds
  var session: URLSession
}

private func testCadenceParams(_ options: TestCadenceOptions) -> CadenceParams {
  CadenceParams(
    connection: BackendConnection(
      baseURL: "https://example.com", credential: "cred", installationId: "install-1"),
    checkInInterval: options.checkInInterval, sdkVersion: "0.1.0", channel: "stable",
    attributes: [:],
    retryInstallationPersistence: {},
    getUpdateState: { .idle },
    getBufferedFacts: { [] },
    clearBufferedFacts: { _ in },
    checkForUpdates: {},
    onEligibilityResponse: { _ in },
    getUpdateEligibility: { nil },
    holdCacheMaxAge: defaultHoldCacheMaxAge,
    stateSyncDebounceSeconds: options.debounceSeconds,
    session: options.session)
}

@Suite(.serialized) struct CadenceCeilingTests {
  @Test @MainActor func intervalAboveTheCeilingIsClampedDownToIt() async {
    let ticker = startCadence(
      testCadenceParams(TestCadenceOptions(checkInInterval: 6 * 60 * 60, session: quietSession())))
    defer { Task { await ticker.stop() } }

    var intervalMs: Double?
    for _ in 0..<50 {
      intervalMs = await ticker.intervalMs()
      if intervalMs != nil { break }
      await Task.yield()
    }

    guard let resolvedIntervalMs = intervalMs else {
      Issue.record("expected intervalMs() to resolve once the ticker attached its bindings")
      return
    }

    let ceilingMs = maxIntervalSeconds * 1000
    // Jitter is +/-10-15%, applied on top of the clamp -- bound generously
    // around the ceiling rather than asserting an exact value.
    #expect(resolvedIntervalMs >= ceilingMs * 0.8)
    #expect(resolvedIntervalMs <= ceilingMs * 1.2)
  }
}

@Suite(.serialized) struct CadenceStateSyncDebounceTests {
  @Test func applyingBypassesAnOpenDebounceWindow() async {
    CountingCheckInProtocol.requestCount = 0
    let ticker = CadenceTicker(
      params: testCadenceParams(TestCadenceOptions(debounceSeconds: 5, session: countingSession())))

    await ticker.stateChanged()
    await ticker.syncBeforeApply()

    #expect(CountingCheckInProtocol.requestCount == 2)
    await ticker.stop()
  }

  // A long window proves the leading edge is immediate, as applying
  // cannot wait until after the process exits.
  @Test func aLoneStateChangeFiresImmediatelyWithoutWaitingOutTheWindow() async {
    CountingCheckInProtocol.requestCount = 0
    let ticker = CadenceTicker(
      params: testCadenceParams(TestCadenceOptions(debounceSeconds: 5, session: countingSession())))

    await ticker.stateChanged()

    #expect(CountingCheckInProtocol.requestCount == 1)
  }

  // A burst sends its first state immediately and its settled state once.
  @Test func aBurstFiresImmediatelyThenOnceMoreAfterSettling() async {
    CountingCheckInProtocol.requestCount = 0
    let ticker = CadenceTicker(
      params: testCadenceParams(
        TestCadenceOptions(debounceSeconds: 0.05, session: countingSession())))

    await ticker.stateChanged()
    #expect(CountingCheckInProtocol.requestCount == 1)  // leading fire

    await ticker.stateChanged()
    await ticker.stateChanged()
    // still inside the window, no second fire yet
    #expect(CountingCheckInProtocol.requestCount == 1)

    try? await Task.sleep(nanoseconds: 300_000_000)  // well past the 0.05s window

    #expect(CountingCheckInProtocol.requestCount == 2)  // trailing fire landed
  }

  @Test func twoStateChangesFartherApartThanTheWindowProduceTwoCheckIns() async {
    CountingCheckInProtocol.requestCount = 0
    let ticker = CadenceTicker(
      params: testCadenceParams(
        TestCadenceOptions(debounceSeconds: 0.05, session: countingSession())))

    await ticker.stateChanged()
    try? await Task.sleep(nanoseconds: 200_000_000)
    await ticker.stateChanged()
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(CountingCheckInProtocol.requestCount == 2)
  }
}
