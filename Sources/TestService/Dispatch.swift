import Foundation

@testable import BarrelKit

/// Routes run on background threads; UI-adjacent adapter work stays on the main actor.
func runOnMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
  DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}

/// Safe only because the calling thread is never one of Swift's own
/// concurrency-executor threads (this server runs on a plain, dedicated OS
/// thread) -- calling this inside a `Task` or `@MainActor` risks deadlock.
func runBlocking<T: Sendable>(
  timeout: TimeInterval = 15, fallback: T, _ operation: @escaping @Sendable () async -> T
) -> T {
  let semaphore = DispatchSemaphore(value: 0)
  let box: Locked<T?> = Locked(nil)

  Task {
    let result = await operation()
    box.write { $0 = result }
    semaphore.signal()
  }

  guard semaphore.wait(timeout: .now() + timeout) == .success else {
    return fallback
  }
  guard let result = box.read({ $0 }) else {
    preconditionFailure("runBlocking: operation finished without producing a result")
  }
  return result
}
