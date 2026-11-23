import Darwin
import Foundation
import Testing

@testable import BarrelKit

private actor WriteProbe {
  var timedOut = false

  func markTimedOut() { timedOut = true }
}

@Suite struct PersistenceWriterTests {
  @Test func aBlockedDiskWriteDoesNotBlockBufferSnapshots() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "barrel-disk-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("facts.json").path
    let store = BufferedFactsStore()
    await store.configure(filePath: path)
    try #require(mkfifo(path, 0o600) == 0)

    let readerGate = DispatchSemaphore(value: 0)
    let probe = WriteProbe()
    let reader = Task {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global().async {
          readerGate.wait()
          let fd = open(path, O_RDONLY | O_NONBLOCK)
          guard fd >= 0 else {
            continuation.resume(returning: false)
            return
          }
          defer { close(fd) }
          var bytes = [UInt8](repeating: 0, count: 4096)
          // Keep the reader alive until the queued writer closes its end.
          var received = false
          let deadline = Date().addingTimeInterval(5)
          while Date() < deadline {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 { received = true }
            if count == 0 && received { break }
            if count < 0 && errno != EAGAIN { break }
            if count <= 0 { Thread.sleep(forTimeInterval: 0.005) }
          }
          continuation.resume(returning: received)
        }
      }
    }
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      await probe.markTimedOut()
      readerGate.signal()
    }

    await store.recordUpdateState(.checking)
    let snapshot = await store.snapshot()
    let timedOut = await probe.timedOut
    readerGate.signal()
    let persisted = await reader.value
    watchdog.cancel()
    await watchdog.value

    #expect(!timedOut, "Reading the in-memory buffer must not wait for disk I/O")
    #expect(snapshot.count == 1)
    #expect(persisted, "The queued write must eventually reach disk")
  }
}

private final class SnapshotWriteGate: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let released = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0

  func beforeWrite() {
    let first = lock.withLock {
      count += 1
      return count == 1
    }
    if first {
      entered.signal()
      released.wait()
    }
  }

  func writes() -> Int { lock.withLock { count } }
}

@Suite struct PersistenceCoalescingTests {
  @Test func blockedWritesRetainOnlyTheLatestPendingSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let path = directory.appendingPathComponent("snapshot.json").path
    let gate = SnapshotWriteGate()
    PersistenceWriter.setBeforeQueuedWrite { candidate in
      if candidate == path { gate.beforeWrite() }
    }
    defer {
      gate.released.signal()
      PersistenceWriter.setBeforeQueuedWrite { _ in }
      try? FileManager.default.removeItem(at: directory)
    }

    PersistenceWriter.persist(path: path, data: Data("0".utf8))
    let started = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: gate.entered.wait(timeout: .now() + 5) == .success)
      }
    }
    #expect(started)
    for value in 1...1000 { PersistenceWriter.persist(path: path, data: Data("\(value)".utf8)) }
    gate.released.signal()
    await PersistenceWriter.waitForPendingWrites()

    #expect(gate.writes() == 2)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "1000")
  }
}
