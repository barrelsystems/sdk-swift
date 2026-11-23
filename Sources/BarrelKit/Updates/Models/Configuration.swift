import Foundation

extension Updates {
  public struct Config: Sendable {
    /// Nominal cadence in seconds, clamped to 15 minutes–2 hours.
    public var checkInInterval: TimeInterval?
    public var attributes: [String: String]
    public var channel: String
    public var autoDownload: Bool
    public var updateFeedURL: String?
    /// Cached Hold lifetime in seconds; default 24 hours, maximum seven days.
    public var holdCacheMaxAge: TimeInterval?

    public init(
      checkInInterval: TimeInterval? = nil, attributes: [String: String] = [:],
      channel: String = "stable",
      autoDownload: Bool = true, updateFeedURL: String? = nil, holdCacheMaxAge: TimeInterval? = nil
    ) {
      self.checkInInterval = checkInInterval
      self.attributes = attributes
      self.channel = channel
      self.autoDownload = autoDownload
      self.updateFeedURL = updateFeedURL
      self.holdCacheMaxAge = holdCacheMaxAge
    }
  }
}
