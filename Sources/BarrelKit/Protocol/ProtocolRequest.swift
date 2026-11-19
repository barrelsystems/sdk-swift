import Foundation

private let requestTimeout: TimeInterval = 10

/// Shared shape behind both `sendCheckIn` and `checkPreAction`: POST a signed
/// body, reject a non-2xx or unrecognized `protocolVersion`, decode the
/// common `CheckInResponse` envelope. Any failure fails open, returning `nil`.
func postToBarrel<Body: Encodable>(
  baseURL: String, path: String, credential: String, body: Body, label: String,
  log: (@Sendable (String) -> Void)?,
  session: URLSession = .shared
) async -> CheckInResponse? {
  guard let url = URL(string: "\(baseURL)/\(path)") else { return nil }
  var request = URLRequest(url: url, timeoutInterval: requestTimeout)
  request.httpMethod = "POST"
  request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization")
  request.setValue("application/json", forHTTPHeaderField: "content-type")

  do {
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      log?("\(label): received a non-2xx response")
      return nil
    }

    let parsed = try JSONDecoder().decode(CheckInResponse.self, from: data)
    guard parsed.protocolVersion == protocolVersion else {
      log?("\(label): rejected unrecognized protocolVersion \(parsed.protocolVersion)")
      return nil
    }

    log?("\(label): succeeded")
    return parsed
  } catch {
    log?("\(label): failed (\(error.localizedDescription))")
    return nil
  }
}
