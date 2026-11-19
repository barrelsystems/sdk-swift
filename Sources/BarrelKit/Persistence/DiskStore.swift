import Foundation

/// Non-blocking, fail-open disk persistence with a synchronous exit-time
/// fallback. Each caller is already an actor serializing its own calls,
/// so this needs no mutex of its own.
enum DiskStore {
  // `atexit`'s C callback runs outside Swift's isolation checking
  // entirely, hence `nonisolated(unsafe)` -- updated on every write so
  // the last known snapshot is always what a sudden exit falls back to.
  nonisolated(unsafe) private static var lastSnapshots: [String: Data] = [:]
  nonisolated(unsafe) private static var exitHandlerRegistered = false
  private static let lock = NSLock()

  static func persist(path: String, data: Data) async {
    lock.withLock {
      lastSnapshots[path] = data
      registerExitFallbackIfNeeded()
    }

    do {
      try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: URL(fileURLWithPath: path))
    } catch {
      // Fail open: disk full, permission denied, etc. The in-memory value
      // stays authoritative for this process -- the next write is the retry.
    }
  }

  private static func registerExitFallbackIfNeeded() {
    guard !exitHandlerRegistered else { return }
    exitHandlerRegistered = true
    atexit {
      let snapshots = DiskStore.lock.withLock { DiskStore.lastSnapshots }
      for (path, data) in snapshots {
        try? FileManager.default.createDirectory(
          at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
      }
    }
  }
}
