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

    await store.recordAdapterState(.checking)
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
