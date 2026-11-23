import Foundation

extension Updates {

  /// Native lifecycle state carried by each subscription snapshot.
  public enum State: Sendable, Equatable {
    /// No check has run yet, or the last one found nothing.
    case idle
    /// A check is in flight.
    case checking
    /// A check found an update not yet downloaded.
    case available(releaseNotes: String?)
    /// The update is downloading. `progress` is 0-100 when Sparkle reports one.
    case downloading(progress: Int?)
    /// The update finished downloading and is ready to install.
    case downloaded
    /// `quitAndInstall()`'s reply has been issued -- the host process may
    /// already be gone by the time anything observes this.
    case applying
    /// The user or Sparkle cancelled an in-progress download or install.
    case updateCancelled
    /// Something in the check/download/install pipeline failed.
    case failed(category: Updates.FailureCategory, code: Updates.FailureMode, platformCode: String)
  }

}

extension Updates.State: Codable {
  private enum CodingKeys: String, CodingKey {
    case type, progress, category, code, platformCode, releaseNotes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "idle": self = .idle
    case "checking": self = .checking
    case "available":
      self = .available(
        releaseNotes: try container.decodeIfPresent(String.self, forKey: .releaseNotes))
    case "downloading":
      self = .downloading(progress: try container.decodeIfPresent(Int.self, forKey: .progress))
    case "downloaded": self = .downloaded
    case "applying": self = .applying
    case "update-cancelled": self = .updateCancelled
    case "failed":
      self = .failed(
        category: try container.decode(Updates.FailureCategory.self, forKey: .category),
        code: try container.decode(Updates.FailureMode.self, forKey: .code),
        platformCode: try container.decode(String.self, forKey: .platformCode)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container, debugDescription: "Unknown Updates.State type \(type)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .idle: try container.encode("idle", forKey: .type)
    case .checking: try container.encode("checking", forKey: .type)
    case .available(let releaseNotes):
      try container.encode("available", forKey: .type)
      try container.encodeIfPresent(releaseNotes, forKey: .releaseNotes)
    case .downloading(let progress):
      try container.encode("downloading", forKey: .type)
      try container.encodeIfPresent(progress, forKey: .progress)
    case .downloaded: try container.encode("downloaded", forKey: .type)
    case .applying: try container.encode("applying", forKey: .type)
    case .updateCancelled: try container.encode("update-cancelled", forKey: .type)
    case .failed(let category, let code, let platformCode):
      try container.encode("failed", forKey: .type)
      try container.encode(category, forKey: .category)
      try container.encode(code, forKey: .code)
      try container.encode(platformCode, forKey: .platformCode)
    }
  }
}
