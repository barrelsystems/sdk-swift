import Foundation
import Testing

@testable import BarrelKit

private final class MockHostControlProtocol: URLProtocol {
  nonisolated(unsafe) static var statusCode = 200
  nonisolated(unsafe) static var body = #"{"protocolVersion":1,"policy":"{}","signature":"sig"}"#

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)
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

// `SPUUserUpdateState`'s initializer is `NS_UNAVAILABLE` (no public way to
// construct one), so there's no way to drive the adapter into `.available`
// here -- these two tests cover exactly the seam that's reachable: the
// no-op guard before anything is actually available/downloaded.
@Suite(.serialized) @MainActor struct HostControlTests {
  @Test func downloadUpdateIsANoOpWhenNoUpdateIsAvailable() async {
    MockHostControlProtocol.statusCode = 500
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let control = HostControl(
      params: HostControlParams(
        baseURL: "https://example.com", credential: "cred", installationId: "install-1", autoDownload: false,
        getTrustedKeyPEM: { "key" }, adapter: adapter, session: mockSession()))

    await control.downloadUpdate()
    #expect(adapter.getAdapterState() == .idle)
  }

  @Test func applyUpdateIsANoOpBeforeAnythingHasDownloaded() async {
    MockHostControlProtocol.statusCode = 500
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    let control = HostControl(
      params: HostControlParams(
        baseURL: "https://example.com", credential: "cred", installationId: "install-1", autoDownload: false,
        getTrustedKeyPEM: { "key" }, adapter: adapter, session: mockSession()))

    await control.applyUpdate()
    #expect(adapter.getAdapterState() == .idle)
  }
}
