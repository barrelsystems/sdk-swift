import Foundation

/// Reads the persisted installation ID, or generates and persists a fresh
/// one. A write failure keeps the in-memory ID rather than regenerating;
/// the actor itself serializes concurrent callers onto one resolution.
actor InstallationIdStore {
  private var cachedId: String?
  private var pendingPersistence: Task<Void, Never>?

  func getOrCreate(filePath: String) async -> String {
    if cachedId == nil, let existing = readExisting(filePath: filePath) {
      cachedId = existing
      return existing
    }

    let id = cachedId ?? UUID().uuidString.lowercased()
    cachedId = id
    retryPersistence(filePath: filePath)
    await waitForPendingPersistence()

    return id
  }

  func retryPersistence(filePath: String) {
    guard pendingPersistence == nil, let id = cachedId,
      let data = try? JSONEncoder().encode(["installationId": id])
    else { return }

    pendingPersistence = Task {
      PersistenceWriter.persist(path: filePath, data: data)
      await PersistenceWriter.waitForPendingWrites()
      pendingPersistence = nil
    }
  }

  func waitForPendingPersistence() async {
    await pendingPersistence?.value
  }

  private func readExisting(filePath: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
      let parsed = try? JSONDecoder().decode([String: String].self, from: data)
    else { return nil }
    return parsed["installationId"]
  }
}
