import Foundation

/// Normal writes are queued off the caller's actor. The same serial queue
/// protects disk writes and drains before the synchronous exit fallback.
enum PersistenceWriter {
  // The exit callback runs outside actor isolation; this lock protects
  // snapshot updates and queue ordering without holding it during I/O.
  nonisolated(unsafe) private static var lastSnapshots: [String: Data] = [:]
  nonisolated(unsafe) private static var exitHandlerRegistered = false
  nonisolated(unsafe) private static var exiting = false
  private static let lock = NSLock()
  #if DEBUG
    nonisolated(unsafe) private static var beforeQueuedWrite: (@Sendable (String) -> Void)?

    static func setBeforeQueuedWrite(_ observer: @escaping @Sendable (String) -> Void) {
      lock.withLock { beforeQueuedWrite = observer }
    }
  #endif

  private static let writes = DispatchQueue(label: "barrel.persistence")

  static func persist(path: String, data: Data) {
    lock.withLock {
      lastSnapshots[path] = data
      registerExitFallbackIfNeeded()
      guard !exiting else { return }

      writes.async {
        #if DEBUG
          let observer = lock.withLock { beforeQueuedWrite }
          observer?(path)
        #endif
        write(path: path, data: data)
      }
    }
  }

  static func waitForPendingWrites() async {
    await withCheckedContinuation { continuation in
      writes.async { continuation.resume() }
    }
  }

  private static func write(path: String, data: Data) {
    do {
      try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: URL(fileURLWithPath: path))
    } catch {
      // Fail open: memory stays authoritative; the next write retries.
    }
  }

  private static func registerExitFallbackIfNeeded() {
    guard !exitHandlerRegistered else { return }
    exitHandlerRegistered = true

    atexit {
      PersistenceWriter.lock.withLock { PersistenceWriter.exiting = true }

      // The writer never exits the process itself, so draining here is safe.
      PersistenceWriter.writes.sync {
        let snapshots = PersistenceWriter.lock.withLock { PersistenceWriter.lastSnapshots }
        for (path, data) in snapshots { PersistenceWriter.write(path: path, data: data) }
      }
    }
  }
}
