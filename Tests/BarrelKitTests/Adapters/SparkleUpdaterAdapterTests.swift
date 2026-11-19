import Testing

@testable import BarrelKit

@Suite struct SparkleUpdaterAdapterTests {
  @Test @MainActor func onStateChangeNotifiesEveryRegisteredListener() {
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: BufferedFactsStore())
    var first: [AdapterState] = []
    var second: [AdapterState] = []
    adapter.onStateChange { first.append($0) }
    adapter.onStateChange { second.append($0) }

    adapter.showUserInitiatedUpdateCheck(cancellation: {})

    #expect(first == [.checking])
    #expect(second == [.checking])
  }

  // Regression: `recordAdapterState`/`recordUpdateError` were defined on
  // `BufferedFactsStore` but never actually wired up to a real adapter-state
  // transition, so `bufferedFacts` was always empty on every real check-in.
  @Test @MainActor func aStateTransitionLandsInTheBufferedFactsStore() async {
    let store = BufferedFactsStore()
    let adapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: store)

    adapter.showUserInitiatedUpdateCheck(cancellation: {})

    var facts: [BufferedFact] = []
    for _ in 0..<50 {
      facts = await store.snapshot()
      if !facts.isEmpty { break }
      await Task.yield()
    }

    #expect(facts.count == 1)
    guard case .adapterState(let state, _, _, let occurrenceCount) = facts.first else {
      Issue.record("expected an .adapterState fact, got \(String(describing: facts.first))")
      return
    }
    #expect(state == .checking)
    #expect(occurrenceCount == 1)
  }
}
