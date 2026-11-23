import CryptoKit
import Foundation
import Testing

@testable import BarrelKit

private final class MockUpdatesProtocol: URLProtocol {
  nonisolated(unsafe) static var statusCode = 200
  nonisolated(unsafe) static var body =
    #"{"protocolVersion":1,"updateEligibility":"{}","signature":"sig"}"#

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func mockSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MockUpdatesProtocol.self]
  return URLSession(configuration: config)
}

@MainActor private func makeUpdates(
  adapter: SparkleUpdaterAdapter, trustedKeyPEM: @escaping @Sendable () async -> String = { "key" },
  session: URLSession
) -> Updates {
  let updates = Updates()
  updates.adapter = adapter
  updates.hostControl = HostControl(
    params: HostControlParams(
      connection: BackendConnection(
        baseURL: "https://example.com", credential: "cred", installationId: "install-1"),
      getTrustedKeyPEM: trustedKeyPEM, adapter: adapter, recordVersionExpectation: { _ in },
      clearVersionExpectation: {}, completeDeferredTermination: {}, syncApplyingState: {},
      session: session))
  return updates
}

private actor AuthorizationGate {
  private var waiter: CheckedContinuation<String, Never>?
  func key() async -> String { await withCheckedContinuation { waiter = $0 } }
  func isWaiting() -> Bool { waiter != nil }
  func release() {
    waiter?.resume(returning: "key")
    waiter = nil
  }
}

@Suite(.serialized) @MainActor struct UpdatesTests {
  @Test func lateSubscriptionsReceiveTheCurrentSnapshotIndependently() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let updates = Updates()
    updates.adapter = adapter
    adapter.markApplying()

    var first: [Updates.Status] = []
    var second: [Updates.Status] = []
    let firstSubscription = updates.subscribe { first.append($0) }
    let secondSubscription = updates.subscribe { second.append($0) }
    #expect(first.first?.state == .applying)
    #expect(second.first?.state == .applying)

    firstSubscription.remove()
    updates.fireEligibilityChanged(
      .held(issuedAt: "2026-01-01T00:00:00Z", environment: "test", reason: nil, until: nil))
    #expect(first.count == 1)
    #expect(second.count == 2)
    #expect(second.last?.state == .applying)
    #expect(second.last?.eligibility != nil)
    secondSubscription.remove()
  }

  @Test func subscriptionsDeliverInitialAndCompleteSnapshotsAndCanBeRemoved() {
    let updates = Updates()
    var observed: [Updates.Status] = []
    let subscription = updates.subscribe { observed.append($0) }
    #expect(observed.count == 1)
    #expect(observed.first?.state == .idle)
    #expect(observed.first?.eligibility == nil)
    #expect(observed.first?.lastError == nil)

    updates.fireEligibilityChanged(
      .unrestricted(issuedAt: "2026-01-01T00:00:00Z", environment: "test"))
    #expect(observed.count == 2)
    #expect(observed.last?.state == .idle)
    #expect(observed.last?.eligibility != nil)
    subscription.remove()
    subscription.remove()
    updates.fireEligibilityChanged(
      .held(issuedAt: "2026-01-01T00:00:00Z", environment: "test", reason: nil, until: nil))
    #expect(observed.count == 2)
  }

  @Test func actionsReportNotReadyBeforeInitialization() async {
    let updates = Updates()

    await #expect(throws: Updates.ActionError.notReady) { try await updates.download() }
    await #expect(throws: Updates.ActionError.notReady) { try await updates.apply() }
  }

  @Test func publicTerminationHookDefersOnceAndNeverInstallsAHeldUpdate() async throws {
    let key = Curve25519.Signing.PrivateKey()
    MockUpdatesProtocol.body = try signedEligibilityBody(type: "held", signedBy: key)
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    var installs = 0
    adapter.showReady(toInstallAndRelaunch: { choice in
      if choice == .install { installs += 1 }
    })
    let updates = makeUpdates(
      adapter: adapter,
      trustedKeyPEM: { testPublicKeyPEM(fromRawEd25519PublicKey: key.publicKey.rawRepresentation) },
      session: mockSession())

    #expect(Updates().applicationShouldTerminate())
    #expect(!updates.applicationShouldTerminate())
    #expect(!updates.applicationShouldTerminate())
    await updates.waitForActions()
    #expect(installs == 0)
    #expect(updates.snapshot().state == .downloaded)
  }

  @Test func downloadThrowsNoUpdateAvailableWhenNothingIsAvailable() async {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let updates = makeUpdates(adapter: adapter, session: mockSession())

    await #expect(throws: Updates.ActionError.noUpdateAvailable) {
      try await updates.download()
    }
  }

  @Test func applyThrowsNothingDownloadedYetBeforeAnythingHasDownloaded() async {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let updates = makeUpdates(adapter: adapter, session: mockSession())

    await #expect(throws: Updates.ActionError.nothingDownloadedYet) {
      try await updates.apply()
    }
  }

  @Test func applyThrowsHeldWhenAFreshCheckDeniesIt() async throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    MockUpdatesProtocol.statusCode = 200
    MockUpdatesProtocol.body = try signedEligibilityBody(type: "held", signedBy: privateKey)

    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    adapter.showReady(toInstallAndRelaunch: { _ in })
    let updates = makeUpdates(
      adapter: adapter,
      trustedKeyPEM: {
        testPublicKeyPEM(fromRawEd25519PublicKey: privateKey.publicKey.rawRepresentation)
      },
      session: mockSession())

    await #expect(throws: Updates.ActionError.held) {
      try await updates.apply()
    }
    #expect(updates.snapshot().state == .downloaded)
  }

  // Simulate verified completion inside the native reply to exercise an action that settles
  // before its waiter is installed.
  @Test func downloadResolvesOnceTheAdapterReachesDownloaded() async throws {
    MockUpdatesProtocol.statusCode = 200
    MockUpdatesProtocol.body = try signedEligibilityBody(
      type: "unrestricted", signedBy: Curve25519.Signing.PrivateKey())
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let updates = makeUpdates(adapter: adapter, session: mockSession())
    adapter.handleUpdateFound(
      version: "2.0.0", releaseNotes: nil,
      reply: { _ in adapter.showReady(toInstallAndRelaunch: { _ in }) })

    try await updates.download()

    #expect(updates.snapshot().state == .downloaded)
  }
  @Test func concurrentDownloadCannotOverwriteTheFirstWaitingAction() async throws {
    let gate = AuthorizationGate()
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    adapter.handleUpdateFound(version: "2.0.0", releaseNotes: nil) { _ in
      adapter.showReady(toInstallAndRelaunch: { _ in })
    }
    let updates = makeUpdates(
      adapter: adapter, trustedKeyPEM: { await gate.key() }, session: mockSession())
    let first = Task { try await updates.download() }
    for _ in 0..<1000 {
      if await gate.isWaiting() { break }
      await Task.yield()
    }
    let reachedGate = await gate.isWaiting()
    await #expect(throws: Updates.ActionError.alreadyInProgress) { try await updates.download() }
    await gate.release()
    try await first.value
    #expect(reachedGate)
    #expect(updates.snapshot().state == .downloaded)
  }

  @Test func aFreshVerifiedHoldIsVisibleInTheCompleteStatus() async throws {
    let key = Curve25519.Signing.PrivateKey()
    MockUpdatesProtocol.body = try signedEligibilityBody(type: "held", signedBy: key)
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    adapter.showReady(toInstallAndRelaunch: { _ in })
    let updates = makeUpdates(
      adapter: adapter,
      trustedKeyPEM: { testPublicKeyPEM(fromRawEd25519PublicKey: key.publicKey.rawRepresentation) },
      session: mockSession())
    updates.hostControl = HostControl(
      params: HostControlParams(
        connection: BackendConnection(
          baseURL: "https://example.com", credential: "cred", installationId: "id"),
        getTrustedKeyPEM: {
          testPublicKeyPEM(fromRawEd25519PublicKey: key.publicKey.rawRepresentation)
        }, adapter: adapter,
        recordVersionExpectation: { _ in }, clearVersionExpectation: {},
        completeDeferredTermination: {},
        syncApplyingState: {}, session: mockSession(),
        onEligibility: { [weak updates] in updates?.fireEligibilityChanged($0) }))

    await #expect(throws: Updates.ActionError.held) { try await updates.apply() }
    #expect(
      updates.snapshot().eligibility
        == .held(
          issuedAt: "2026-01-01T00:00:00Z", environment: "production", reason: nil, until: nil))
  }

}
