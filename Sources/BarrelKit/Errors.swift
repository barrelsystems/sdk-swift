import Foundation

/// Thrown synchronously by `init()`, and only by `init()` -- every later failure fails open instead.
public struct BarrelConfigError: Error, LocalizedError {
  private let message: String
  public init(_ message: String) { self.message = message }

  public var errorDescription: String? { message }
}
