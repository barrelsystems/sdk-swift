import Foundation

/// Invalid initialization settings that the application can correct.
public struct BarrelConfigError: Error, LocalizedError {
  private let message: String
  public init(_ message: String) { self.message = message }

  public var errorDescription: String? { message }
}
