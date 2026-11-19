import Foundation
import Testing

@testable import BarrelKit

@Suite struct InstallationIdStoreTests {
  @Test func generatesAndPersistsAFreshIdOnFirstCall() async throws {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/installation.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let store = InstallationIdStore()
    let id = await store.getOrCreate(filePath: path)
    #expect(!id.isEmpty)
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test func reusesTheSameIdAcrossInstances() async throws {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/installation.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let first = await InstallationIdStore().getOrCreate(filePath: path)
    let second = await InstallationIdStore().getOrCreate(filePath: path)
    #expect(first == second)
  }
}
