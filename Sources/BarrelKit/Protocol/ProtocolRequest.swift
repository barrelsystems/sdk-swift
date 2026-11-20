import Foundation

private let requestTimeout: TimeInterval = 10

struct PostProtocolRequestParams<Body: Encodable> {
  var baseURL: String
  var path: String
  var credential: String
  var body: Body
  var label: String
  var log: (@Sendable (String) -> Void)?
  var session: URLSession = .shared
}

/// Shared shape behind both `sendCheckIn` and `checkPreAction`: POST a signed
/// body, reject a non-2xx or unrecognized `protocolVersion`, decode the
/// common `CheckInResponse` envelope. Any failure fails open, returning `nil`.
func postProtocolRequest<Body: Encodable>(_ params: PostProtocolRequestParams<Body>) async -> CheckInResponse? {
  guard let url = URL(string: "\(params.baseURL)/\(params.path)") else { return nil }
  var request = URLRequest(url: url, timeoutInterval: requestTimeout)
  request.httpMethod = "POST"
  request.setValue("Bearer \(params.credential)", forHTTPHeaderField: "authorization")
  request.setValue("application/json", forHTTPHeaderField: "content-type")

  do {
    request.httpBody = try JSONEncoder().encode(params.body)
    let (data, response) = try await params.session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      params.log?("\(params.label): received a non-2xx response")
      return nil
    }

    let parsed = try JSONDecoder().decode(CheckInResponse.self, from: data)
    guard parsed.protocolVersion == protocolVersion else {
      params.log?("\(params.label): rejected unrecognized protocolVersion \(parsed.protocolVersion)")
      return nil
    }

    params.log?("\(params.label): succeeded")
    return parsed
  } catch {
    params.log?("\(params.label): failed (\(error.localizedDescription))")
    return nil
  }
}
