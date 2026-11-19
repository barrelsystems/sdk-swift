import Foundation
import Testing

@testable import BarrelKit

@Suite struct CheckInWireFormatTests {
  @Test func passesAnAdapterStateFactThroughVerbatim() {
    let fact = BufferedFact.adapterState(
      state: .checking, firstObservedAt: "2026-01-01T00:00:00.000Z",
      lastObservedAt: "2026-01-01T00:00:00.000Z", occurrenceCount: 1)
    let wire = toWireBufferedFact(fact)
    #expect(wire.kind == "adapterState")
    #expect(wire.state == .checking)
    #expect(wire.phase == nil)
    #expect(wire.failureMode == nil)
    #expect(wire.platformCode == nil)
  }

  // The backend's schema has no `failure`/`title`/`platform` fields --
  // nesting them (the internal, on-disk shape) made every check-in after
  // a buffered update error fail its own schema validation.
  @Test func flattensAnUpdateErrorFactsFailureFieldsOntoTheWireShape() {
    let failure = UpdateFailure(
      phase: .download, failureMode: .manifestUnreachable, title: "Update server unreachable",
      platform: "sparkle", platformCode: "SUAppcastError")
    let fact = BufferedFact.updateError(
      failure: failure, firstObservedAt: "2026-01-01T00:00:00.000Z",
      lastObservedAt: "2026-01-01T00:00:00.000Z", occurrenceCount: 1)
    let wire = toWireBufferedFact(fact)
    #expect(wire.kind == "updateError")
    #expect(wire.phase == .download)
    #expect(wire.failureMode == .manifestUnreachable)
    #expect(wire.platformCode == "SUAppcastError")
    #expect(wire.state == nil)
  }

  @Test func availableStateCarriesReleaseNotesThroughTheWireRoundTrip() throws {
    let state = AdapterState.available(releaseNotes: "Fixes a crash on launch.")
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(AdapterState.self, from: data)
    #expect(decoded == .available(releaseNotes: "Fixes a crash on launch."))
  }

  @Test func availableStateOmitsReleaseNotesFromTheWireWhenAbsent() throws {
    let state = AdapterState.available(releaseNotes: nil)
    let data = try JSONEncoder().encode(state)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["releaseNotes"] == nil)
    let decoded = try JSONDecoder().decode(AdapterState.self, from: data)
    #expect(decoded == .available(releaseNotes: nil))
  }
}
