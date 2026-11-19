/// Thrown synchronously by `init()`, and only by `init()` -- every later failure fails open instead.
public struct BarrelConfigError: Error, CustomStringConvertible {
  public let description: String
  public init(_ message: String) { self.description = message }
}
