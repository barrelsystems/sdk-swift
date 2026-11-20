import Foundation

/// A plain mutex-guarded box -- the one shape `AppcastServer` and
/// `AdapterRegistry` both needed independently.
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
