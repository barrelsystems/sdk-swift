import Foundation

/// Shared SDK connection settings and configuration for enabled update behavior.
public struct InitConfig: Sendable {
  public var credential: String
  public var baseURL: String?
  public var debug: Bool
  public var updates: Updates.Config

  public init(
    credential: String, baseURL: String? = nil, debug: Bool = false,
    updates: Updates.Config = .init()
  ) {
    self.credential = credential
    self.baseURL = baseURL
    self.debug = debug
    self.updates = updates
  }
}
