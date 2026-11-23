import Foundation

/// Shared SDK initialization; update behavior belongs to the Updates module.
@MainActor
public final class BarrelKit {
  public static let shared = BarrelKit()
  public let updates: Updates

  private init() { updates = Updates() }
  init(environment: RuntimeEnvironment) { updates = Updates(environment: environment) }

  public func initialize(_ config: InitConfig) throws {
    try updates.initialize(config)
  }
}
