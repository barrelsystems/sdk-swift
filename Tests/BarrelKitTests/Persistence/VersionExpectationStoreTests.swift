import Foundation
import Testing

@testable import BarrelKit

@Suite struct VersionExpectationStoreTests {
  @Test func returnsNilWhenNothingWasEverExpected() async throws {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/version-expectation.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let store = VersionExpectationStore()
    #expect(await store.read(filePath: path) == nil)
  }

  @Test func persistsAnExpectedVersionAndReadsItBackAcrossInstances() async throws {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/version-expectation.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    await VersionExpectationStore().set(filePath: path, version: "2.0.0")
    #expect(await VersionExpectationStore().read(filePath: path) == "2.0.0")
  }

  @Test func clearingTheExpectationPersistsAcrossInstances() async throws {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/version-expectation.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let store = VersionExpectationStore()
    await store.set(filePath: path, version: "2.0.0")
    await store.clear(filePath: path)

    #expect(await VersionExpectationStore().read(filePath: path) == nil)
  }
}
