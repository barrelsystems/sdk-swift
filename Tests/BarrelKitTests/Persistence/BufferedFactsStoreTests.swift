import Foundation
import Testing

@testable import BarrelKit

@Suite struct BufferedFactsStoreTests {
  @Test func mergesARepeatedAdapterStateInsteadOfAppending() async {
    let store = BufferedFactsStore()
    await store.recordAdapterState(.checking)
    await store.recordAdapterState(.checking)
    let snapshot = await store.snapshot()
    #expect(snapshot.count == 1)
    #expect(snapshot[0].occurrenceCount == 2)
  }

  @Test func distinctAdapterStatesEachGetTheirOwnEntry() async {
    let store = BufferedFactsStore()
    await store.recordAdapterState(.checking)
    await store.recordAdapterState(.available(releaseNotes: nil))
    let snapshot = await store.snapshot()
    #expect(snapshot.count == 2)
  }

  @Test func clearOnlyRemovesExactlyTheSentSnapshot() async {
    let store = BufferedFactsStore()
    await store.recordAdapterState(.checking)
    let sent = await store.snapshot()
    await store.recordAdapterState(.available(releaseNotes: nil))  // recorded after the snapshot was taken
    await store.clear(sent: sent)

    let remaining = await store.snapshot()
    #expect(remaining.count == 1)
    #expect(remaining[0] != sent[0])
  }

  @Test func acknowledgmentPreservesAnUnsentEqualValuedObservation() async throws {
    let store = BufferedFactsStore(now: { "2026-01-01T00:00:00Z" })
    await store.recordAdapterState(.checking)
    let sent = await store.snapshot()
    await store.recordAdapterState(.downloaded)
    await store.recordAdapterState(.checking)
    let before = await store.snapshot()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try encoder.encode(before[0]) == encoder.encode(before[2]))

    await store.clear(sent: sent)
    let remaining = await store.snapshot()
    #expect(remaining.count == 2)
    #expect(remaining == Array(before.suffix(2)))

    await store.clear(sent: sent)
    #expect(await store.snapshot() == remaining)
  }

  @Test func acknowledgmentCannotClearAnEqualReplacementAfterEviction() async {
    let store = BufferedFactsStore(now: { "2026-01-01T00:00:00Z" })
    await store.recordAdapterState(.checking)
    let sent = await store.snapshot()
    for progress in 0..<32 {
      await store.recordAdapterState(.downloading(progress: progress))
    }
    await store.recordAdapterState(.checking)
    let before = await store.snapshot()

    await store.clear(sent: sent)
    #expect(await store.snapshot() == before)
  }

  @Test func aFullBufferOfTerminalFactsIsNeverDisplacedByAnIntermediateOne() async {
    let store = BufferedFactsStore()
    // Fill the buffer with 32 distinct terminal ("failed") facts -- each
    // discriminated by a unique platformCode, so none merge.
    for i in 0..<32 {
      await store.recordAdapterState(
        .failed(category: .updater, code: .unknown, platformCode: "code-\(i)"))
    }
    #expect(await store.snapshot().count == 32)

    // An incoming intermediate ("checking") fact must be dropped, not evict a terminal one.
    await store.recordAdapterState(.checking)
    let snapshot = await store.snapshot()
    #expect(snapshot.count == 32)
    #expect(
      !snapshot.contains {
        if case .adapterState(.checking, _, _, _, _) = $0 { return true }
        return false
      })
  }

  @Test func neverPersistsTitleAndRederivesItOnReloadFromDisk() async {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/facts.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let failure = UpdateFailure(
      phase: .download, failureMode: .downloadTransportFailed,
      title: "The update download failed at the network layer.",
      platform: "sparkle", platformCode: "test-code")

    let store = BufferedFactsStore()
    await store.configure(filePath: path)
    await store.recordUpdateError(failure)
    await PersistenceWriter.waitForPendingWrites()

    let onDisk = try? Data(contentsOf: URL(fileURLWithPath: path))
    let onDiskString = onDisk.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    #expect(!onDiskString.contains("title"))
    #expect(!onDiskString.contains("network layer"))

    // A fresh instance reloading from disk must still see a real title --
    // re-derived from `failureMode`, not read back from the file.
    let reloaded = BufferedFactsStore()
    await reloaded.configure(filePath: path)
    let snapshot = await reloaded.snapshot()
    guard case .updateError(let reloadedFailure, _, _, _, _) = snapshot.first else {
      Issue.record("expected a reloaded updateError fact")
      return
    }
    #expect(reloadedFailure.title == resolveFailureTitle(.downloadTransportFailed))
  }

  @Test func anIntermediateFactIsEvictedToMakeRoomForAnotherIntermediateFact() async {
    let store = BufferedFactsStore()
    await store.recordAdapterState(.checking)
    for i in 1..<32 {
      await store.recordAdapterState(
        .failed(category: .updater, code: .unknown, platformCode: "code-\(i)"))
    }
    #expect(await store.snapshot().count == 32)

    await store.recordAdapterState(.available(releaseNotes: nil))
    let snapshot = await store.snapshot()
    #expect(snapshot.count == 32)
    #expect(
      !snapshot.contains {
        if case .adapterState(.checking, _, _, _, _) = $0 { return true }
        return false
      })
    #expect(
      snapshot.contains {
        if case .adapterState(.available(releaseNotes: nil), _, _, _, _) = $0 { return true }
        return false
      })
  }
}
