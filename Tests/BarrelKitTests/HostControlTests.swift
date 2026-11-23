import CryptoKit
import Foundation
import Testing

@testable import BarrelKit

/// Use a real signature to distinguish a verified Hold from a verification failure that must
/// fail open.

private final class MockHostControlProtocol: URLProtocol {
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
  config.protocolClasses = [MockHostControlProtocol.self]
  return URLSession(configuration: config)
}

// These cases exercise the no-update guards without constructing unavailable native updater
// state.
@Suite(.serialized) @MainActor struct HostControlTests {
  @Test func downloadUpdateIsANoOpWhenNoUpdateIsAvailable() async {
    MockHostControlProtocol.statusCode = 500
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let control = HostControl(
      params: HostControlParams(
        connection: BackendConnection(
          baseURL: "https://example.com", credential: "cred", installationId: "install-1"),
        getTrustedKeyPEM: { "key" }, adapter: adapter, recordVersionExpectation: { _ in },
        clearVersionExpectation: {}, completeDeferredTermination: {}, syncApplyingState: {},
        session: mockSession()))

    #expect(await control.downloadUpdate() == false)
    #expect(adapter.getUpdateState() == .idle)
  }

  @Test func applyUpdateIsANoOpBeforeAnythingHasDownloaded() async {
    MockHostControlProtocol.statusCode = 500
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let control = HostControl(
      params: HostControlParams(
        connection: BackendConnection(
          baseURL: "https://example.com", credential: "cred", installationId: "install-1"),
        getTrustedKeyPEM: { "key" }, adapter: adapter, recordVersionExpectation: { _ in },
        clearVersionExpectation: {}, completeDeferredTermination: {}, syncApplyingState: {},
        session: mockSession()))

    let applied = await control.applyUpdate()
    #expect(applied == false)
    #expect(adapter.getUpdateState() == .idle)
  }

  // Drive the real install reply and verify applying sync completes
  // between marking the state and invoking the native install callback.
  @Test func applyUpdateAwaitsSyncApplyingStateBetweenMarkApplyingAndQuitAndInstall() async {
    MockHostControlProtocol.statusCode = 200
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let observation = ApplySyncObservation()
    adapter.showReady(toInstallAndRelaunch: { _ in observation.installReplyIssued = true })

    let control = HostControl(
      params: HostControlParams(
        connection: BackendConnection(
          baseURL: "https://example.com", credential: "cred", installationId: "install-1"),
        getTrustedKeyPEM: { "key" }, adapter: adapter, recordVersionExpectation: { _ in },
        clearVersionExpectation: {},
        completeDeferredTermination: {},
        syncApplyingState: {
          await MainActor.run {
            observation.stateDuringSync = adapter.getUpdateState()
            observation.installReplyAlreadyIssuedDuringSync = observation.installReplyIssued
          }
        },
        session: mockSession()))

    #expect(await control.applyUpdate())

    #expect(observation.stateDuringSync == .applying)
    #expect(observation.installReplyAlreadyIssuedDuringSync == false)
    #expect(observation.installReplyIssued == true)
  }

  // A fresh Hold prevents installation but must still complete the previously deferred
  // ordinary quit.
  @Test func applyUpdateForTerminationCompletesTheDeferralWhenAFreshCheckDeniesTheApply()
    async throws
  {
    let privateKey = Curve25519.Signing.PrivateKey()
    MockHostControlProtocol.statusCode = 200
    MockHostControlProtocol.body = try signedEligibilityBody(type: "held", signedBy: privateKey)

    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let observation = ApplySyncObservation()
    adapter.showReady(toInstallAndRelaunch: { _ in observation.installReplyIssued = true })

    let control = HostControl(
      params: HostControlParams(
        connection: BackendConnection(
          baseURL: "https://example.com", credential: "cred", installationId: "install-1"),
        getTrustedKeyPEM: {
          testPublicKeyPEM(fromRawEd25519PublicKey: privateKey.publicKey.rawRepresentation)
        },
        adapter: adapter, recordVersionExpectation: { _ in }, clearVersionExpectation: {},
        completeDeferredTermination: { observation.deferredTerminationCompleted = true },
        syncApplyingState: {}, session: mockSession()))

    await control.applyUpdateForTermination()

    #expect(observation.deferredTerminationCompleted == true)
    #expect(observation.installReplyIssued == false)
    #expect(adapter.getUpdateState() == .downloaded)
  }
}

// A plain captured `var` can't safely cross into the `@Sendable`
// `syncApplyingState` closure -- this holds the test's shared mutable
// state on the MainActor instead, the same place `adapter` itself lives.
@MainActor private final class ApplySyncObservation {
  var installReplyIssued = false
  var stateDuringSync: Updates.State?
  var installReplyAlreadyIssuedDuringSync = false
  var deferredTerminationCompleted = false
}
