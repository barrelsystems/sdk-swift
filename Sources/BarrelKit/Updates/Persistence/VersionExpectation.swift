import Foundation

/// Persists which version an apply attempt expected to be
/// running, so the next startup can confirm it actually landed.
actor VersionExpectationStore {
  /// Call once at startup, before deciding whether the previous
  /// session's apply attempt actually landed.
  func read(filePath: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
      let parsed = try? JSONDecoder().decode([String: String].self, from: data)
    else { return nil }
    return parsed["expectedVersion"]
  }

  /// Call immediately before triggering apply, with the version being applied.
  func set(filePath: String, version: String) async {
    if let data = try? JSONEncoder().encode(["expectedVersion": version]) {
      PersistenceWriter.persist(path: filePath, data: data)
      await PersistenceWriter.waitForPendingWrites()
    }
  }

  /// Call once the current startup's expectation has been resolved either way.
  func clear(filePath: String) async {
    if let data = try? JSONEncoder().encode([String: String]()) {
      PersistenceWriter.persist(path: filePath, data: data)
      await PersistenceWriter.waitForPendingWrites()
    }
  }
}
