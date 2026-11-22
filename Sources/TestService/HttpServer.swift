import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// One parsed request: enough for this service's own small, fixed set of
/// JSON-body routes -- no chunked transfer, no keep-alive, no file uploads.
struct HttpRequest {
  let method: String
  let path: String
  let body: Data
}

/// Generous headroom over any real body this service's routes expect
/// (base64 keys, check-in/policy JSON, event payloads -- all well under a
/// few KB), while still bounding a harness-controlled `Content-Length`.
private let maxRequestBodyBytes = 1 << 20  // 1 MiB

struct HttpResponse {
  let status: Int
  let body: Data

  static func json(_ status: Int, _ object: Encodable) -> HttpResponse {
    guard let data = try? JSONEncoder().encode(AnyEncodable(object)) else {
      return HttpResponse(status: 500, body: Data())
    }
    return HttpResponse(status: status, body: data)
  }

  static func empty(_ status: Int) -> HttpResponse {
    HttpResponse(status: status, body: Data())
  }
}

/// `Encodable` is a protocol, not a concrete type -- this erases it so a
/// route handler can return any concrete `Encodable` through one signature.
private struct AnyEncodable: Encodable {
  private let encodeImpl: (Encoder) throws -> Void
  init(_ wrapped: Encodable) { encodeImpl = wrapped.encode }
  func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}

/// A minimal HTTP/1.1 server over raw POSIX sockets for this service's
/// own small, fixed request shapes. Bind before `run()`; concurrent
/// request handlers share only the immutable routing configuration.
final class MinimalHttpServer: @unchecked Sendable {
  typealias Handler = @Sendable (HttpRequest) -> HttpResponse

  private let handler: Handler
  private var listenSocket: Int32 = -1

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  /// Binds to an OS-assigned ephemeral port and returns it.
  func start() -> UInt16 {
    listenSocket = socket(AF_INET, SOCK_STREAM, 0)
    var reuse: Int32 = 1
    setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_ANY
    address.sin_port = 0  // ask the OS for a free port
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(listenSocket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    precondition(bindResult == 0, "failed to bind test-service listen socket")
    precondition(listen(listenSocket, 16) == 0, "failed to listen on test-service socket")

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(listenSocket, sockaddrPointer, &length)
      }
    }
    return boundAddress.sin_port.byteSwapped
  }

  /// Allows observations while an action is waiting on its backend response.
  func run() {
    while true {
      let client = accept(listenSocket, nil, nil)
      guard client >= 0 else { continue }
      DispatchQueue.global().async { [self] in
        defer { close(client) }
        guard let request = readRequest(from: client) else { return }
        let response = handler(request)
        writeResponse(response, to: client)
      }
    }
  }

  private func readRequest(from socket: Int32) -> HttpRequest? {
    var buffer = Data()
    var headerEnd: Range<Data.Index>?

    while headerEnd == nil {
      var chunk = [UInt8](repeating: 0, count: 4096)
      let bytesRead = recv(socket, &chunk, chunk.count, 0)
      if bytesRead <= 0 { return nil }
      buffer.append(chunk, count: bytesRead)
      headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
    }

    guard let headerEnd else { return nil }
    let headerData = buffer[..<headerEnd.lowerBound]
    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: true)
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    let method = String(parts[0])
    let path = String(parts[1])

    let contentLength =
      lines.dropFirst()
      .first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { $0.split(separator: ":").last }
      .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0

    // The harness controls this header -- bound it well before the body
    // reaches any `JSONDecoder`/`JSONSerialization` call downstream, so a
    // bogus huge value can't drive unbounded memory growth here.
    guard contentLength <= maxRequestBodyBytes else { return nil }

    var body = Data(buffer[headerEnd.upperBound...])
    while body.count < contentLength {
      var chunk = [UInt8](repeating: 0, count: 4096)
      let bytesRead = recv(socket, &chunk, chunk.count, 0)
      if bytesRead <= 0 { break }
      body.append(chunk, count: bytesRead)
    }

    return HttpRequest(method: method, path: path, body: body)
  }

  private func writeResponse(_ response: HttpResponse, to socket: Int32) {
    let statusText = httpStatusText(response.status)
    var head = "HTTP/1.1 \(response.status) \(statusText)\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(response.body.count)\r\n"
    head += "Connection: close\r\n\r\n"

    var payload = Data(head.utf8)
    payload.append(response.body)
    payload.withUnsafeBytes { bytes in
      _ = send(socket, bytes.baseAddress, bytes.count, 0)
    }
  }

  private func httpStatusText(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 204: return "No Content"
    case 404: return "Not Found"
    default: return "Error"
    }
  }
}
