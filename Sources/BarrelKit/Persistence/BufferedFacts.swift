import Foundation

private let maxBufferedFacts = 32
private let terminalAdapterStates: Set<String> = ["downloaded", "failed", "update-cancelled"]

public enum BufferedFact: Sendable, Equatable {
  case adapterState(state: AdapterState, firstObservedAt: String, lastObservedAt: String, occurrenceCount: Int)
  case updateError(failure: UpdateFailure, firstObservedAt: String, lastObservedAt: String, occurrenceCount: Int)
}

extension BufferedFact: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, state, failure, firstObservedAt, lastObservedAt, occurrenceCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    let firstObservedAt = try container.decode(String.self, forKey: .firstObservedAt)
    let lastObservedAt = try container.decode(String.self, forKey: .lastObservedAt)
    let occurrenceCount = try container.decode(Int.self, forKey: .occurrenceCount)
    switch kind {
    case "adapterState":
      self = .adapterState(
        state: try container.decode(AdapterState.self, forKey: .state),
        firstObservedAt: firstObservedAt, lastObservedAt: lastObservedAt, occurrenceCount: occurrenceCount)
    case "updateError":
      self = .updateError(
        failure: try container.decode(UpdateFailure.self, forKey: .failure),
        firstObservedAt: firstObservedAt, lastObservedAt: lastObservedAt, occurrenceCount: occurrenceCount)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "Unknown BufferedFact kind \(kind)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .adapterState(let state, let first, let last, let count):
      try container.encode("adapterState", forKey: .kind)
      try container.encode(state, forKey: .state)
      try container.encode(first, forKey: .firstObservedAt)
      try container.encode(last, forKey: .lastObservedAt)
      try container.encode(count, forKey: .occurrenceCount)
    case .updateError(let failure, let first, let last, let count):
      try container.encode("updateError", forKey: .kind)
      try container.encode(failure, forKey: .failure)
      try container.encode(first, forKey: .firstObservedAt)
      try container.encode(last, forKey: .lastObservedAt)
      try container.encode(count, forKey: .occurrenceCount)
    }
  }

  var firstObservedAt: String {
    switch self {
    case .adapterState(_, let v, _, _), .updateError(_, let v, _, _): return v
    }
  }
  var lastObservedAt: String {
    switch self {
    case .adapterState(_, _, let v, _), .updateError(_, _, let v, _): return v
    }
  }
  var occurrenceCount: Int {
    switch self {
    case .adapterState(_, _, _, let v), .updateError(_, _, _, let v): return v
    }
  }
}

private struct Classification {
  var discriminant: String
  var priority: Int
}

private func classify(_ fact: BufferedFact) -> Classification {
  switch fact {
  case .updateError(let failure, _, _, _):
    return Classification(
      discriminant: "updateError:\(failure.failureMode.rawValue):\(failure.platformCode)", priority: 1)
  case .adapterState(let state, _, _, _):
    if case .failed(_, let code, let platformCode) = state {
      return Classification(discriminant: "adapterState:failed:\(code.rawValue):\(platformCode)", priority: 1)
    }
    let typeKey = adapterStateTypeKey(state)
    return Classification(
      discriminant: "adapterState:\(typeKey)",
      priority: terminalAdapterStates.contains(typeKey) ? 1 : 0)
  }
}

private func adapterStateTypeKey(_ state: AdapterState) -> String {
  switch state {
  case .idle: return "idle"
  case .checking: return "checking"
  case .available: return "available"
  case .downloading: return "downloading"
  case .downloaded: return "downloaded"
  case .updateCancelled: return "update-cancelled"
  case .failed: return "failed"
  }
}

/// Appends observed facts, merging into a matching entry by discriminant,
/// bounded at 32 with priority-and-recency eviction. Disk persistence only
/// guards against a process restart -- it never gates normal operation.
actor BufferedFactsStore {
  private var buffer: [BufferedFact] = []
  private var filePath: String?

  private func persistBuffer() async {
    guard let path = filePath, let data = try? JSONEncoder().encode(["facts": buffer]) else { return }
    await DiskStore.persist(path: path, data: data)
  }

  /// Hydrates the in-memory buffer from disk. Call once at startup, before any fact is recorded.
  func configure(filePath: String) {
    self.filePath = filePath
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
      let parsed = try? JSONDecoder().decode([String: [BufferedFact]].self, from: data)
    else { return }
    buffer = parsed["facts"] ?? []
  }

  /// A snapshot of the current facts, for inclusion in a check-in request. Never the live buffer.
  func snapshot() -> [BufferedFact] { buffer }

  /// Clears exactly the facts in `sent`; call only once ingestion ACKs the
  /// check-in that carried them. A fact recorded after `sent` was taken
  /// must survive.
  func clear(sent: [BufferedFact]) async {
    buffer = buffer.filter { !sent.contains($0) }
    await persistBuffer()
  }

  func recordAdapterState(_ state: AdapterState) async {
    let now = ISO8601DateFormatter().string(from: Date())
    await upsert(.adapterState(state: state, firstObservedAt: now, lastObservedAt: now, occurrenceCount: 1))
  }

  func recordUpdateError(_ failure: UpdateFailure) async {
    let now = ISO8601DateFormatter().string(from: Date())
    await upsert(.updateError(failure: failure, firstObservedAt: now, lastObservedAt: now, occurrenceCount: 1))
  }

  private func upsert(_ candidate: BufferedFact) async {
    let classification = classify(candidate)
    if let existingIndex = buffer.firstIndex(where: { classify($0).discriminant == classification.discriminant }) {
      let existing = buffer[existingIndex]
      buffer[existingIndex] = withMergedTimestamps(
        candidate, firstObservedAt: existing.firstObservedAt, occurrenceCount: existing.occurrenceCount + 1)
      await persistBuffer()
      return
    }

    if buffer.count >= maxBufferedFacts {
      guard let evictionIndex = findEvictionCandidateIndex() else { return }
      // A full buffer of terminal facts is never displaced by an incoming
      // intermediate one -- the incoming fact is dropped instead.
      if classify(buffer[evictionIndex]).priority > classification.priority { return }
      buffer.remove(at: evictionIndex)
    }

    buffer.append(candidate)
    await persistBuffer()
  }

  private func withMergedTimestamps(
    _ fact: BufferedFact, firstObservedAt: String, occurrenceCount: Int
  ) -> BufferedFact {
    switch fact {
    case .adapterState(let state, _, let last, _):
      return .adapterState(
        state: state, firstObservedAt: firstObservedAt, lastObservedAt: last, occurrenceCount: occurrenceCount)
    case .updateError(let failure, _, let last, _):
      return .updateError(
        failure: failure, firstObservedAt: firstObservedAt, lastObservedAt: last, occurrenceCount: occurrenceCount)
    }
  }

  private func findEvictionCandidateIndex() -> Int? {
    var worstIndex: Int?
    for index in buffer.indices {
      guard let worst = worstIndex.map({ buffer[$0] }) else {
        worstIndex = index
        continue
      }
      let fact = buffer[index]
      let factPriority = classify(fact).priority
      let worstPriority = classify(worst).priority
      let isWorse =
        factPriority < worstPriority || (factPriority == worstPriority && fact.lastObservedAt < worst.lastObservedAt)
      if isWorse { worstIndex = index }
    }
    return worstIndex
  }
}
