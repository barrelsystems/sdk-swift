import Foundation

/// Protects values shared by HTTP handler threads and the main actor.
final class Locked<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  init(_ value: Value) {
    self.value = value
  }

  func read<T>(_ body: (Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(value)
  }

  func write(_ body: (inout Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&value)
  }
}
