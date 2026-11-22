import Foundation
import Testing

@testable import BarrelKit

/// Intercepts every request made through a session configured with it,
/// so `postProtocolRequest` can be tested without a real network call.
final class MockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))!

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let (response, data) = try Self.handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func mockSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: config)
}

private func jsonResponse(_ url: URL, status: Int, body: String) throws -> (HTTPURLResponse, Data) {
  let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
  return (response, Data(body.utf8))
}

private struct Body: Encodable { var value: String }

// Serialized: every test in this suite mutates the same global
// `MockURLProtocol.handler`, which races under Swift Testing's default
// parallel execution.
@Suite(.serialized) struct ProtocolRequestTests {
  @Test(arguments: [nil, "Beta / Custom"] as [String?])
  func sendsTheHostChannelOnCheckIn(channel: String?) async {
    var config = InitConfig(credential: "cred")
    if let channel { config.channel = channel }

    MockURLProtocol.handler = { request in
      let data: Data

      if let body = request.httpBody {
        data = body
      } else {
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var bytes = [UInt8](repeating: 0, count: 4096)
        var body = Data()

        while stream.hasBytesAvailable {
          let count = stream.read(&bytes, maxLength: bytes.count)
          #expect(count >= 0)
          if count <= 0 { break }

          body.append(contentsOf: bytes.prefix(count))
        }

        data = body
      }

      let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(json["channel"] as? String == (channel ?? "stable"))
      return try jsonResponse(try #require(request.url), status: 200,
        body: #"{"protocolVersion":1,"policy":"{}","signature":"sig"}"#)
    }

    let response = await sendCheckIn(CheckInParams(
      connection: BackendConnection(baseURL: "https://example.com", credential: "cred", installationId: "install"),
      sdkVersion: "1.0.0", channel: config.channel, attributes: [:],
      adapterState: .idle, bufferedFacts: [], log: nil, session: mockSession()))

    #expect(response != nil)
  }

  @Test func decodesASuccessfulResponse() async {
    MockURLProtocol.handler = { request in
      try jsonResponse(
        try #require(request.url), status: 200, body: #"{"protocolVersion":1,"policy":"{}","signature":"sig"}"#)
    }

    let response = await postProtocolRequest(
      PostProtocolRequestParams(
        baseURL: "https://example.com", path: "check-in", credential: "cred", body: Body(value: "x"),
        label: "check-in", log: nil, session: mockSession()))

    #expect(response?.policy == "{}")
  }

  @Test func failsOpenOnANon2xxResponse() async {
    MockURLProtocol.handler = { request in try jsonResponse(try #require(request.url), status: 500, body: "") }

    let response = await postProtocolRequest(
      PostProtocolRequestParams(
        baseURL: "https://example.com", path: "check-in", credential: "cred", body: Body(value: "x"),
        label: "check-in", log: nil, session: mockSession()))

    #expect(response == nil)
  }

  @Test func failsOpenOnAnUnrecognizedProtocolVersion() async {
    MockURLProtocol.handler = { request in
      try jsonResponse(
        try #require(request.url), status: 200, body: #"{"protocolVersion":99,"policy":"{}","signature":"sig"}"#)
    }

    let response = await postProtocolRequest(
      PostProtocolRequestParams(
        baseURL: "https://example.com", path: "check-in", credential: "cred", body: Body(value: "x"),
        label: "check-in", log: nil, session: mockSession()))

    #expect(response == nil)
  }

  @Test func failsOpenOnATransportFailure() async {
    MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

    let response = await postProtocolRequest(
      PostProtocolRequestParams(
        baseURL: "https://example.com", path: "check-in", credential: "cred", body: Body(value: "x"),
        label: "check-in", log: nil, session: mockSession()))

    #expect(response == nil)
  }
}
