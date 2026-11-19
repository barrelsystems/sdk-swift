import Foundation

/// Reads the persisted installation ID, or generates and persists a fresh
/// one. A write failure keeps the in-memory ID rather than regenerating;
/// the actor itself serializes concurrent callers onto one resolution.
actor InstallationIdStore {
  private var cachedId: String?

  func getOrCreate(filePath: String) async -> String {
    if let cachedId { return cachedId }

    if let existing = readExisting(filePath: filePath) {
      cachedId = existing
      return existing
    }

    let id = UUID().uuidString.lowercased()
    cachedId = id
    if let data = try? JSONEncoder().encode(["installationId": id]) {
      await DiskStore.persist(path: filePath, data: data)
    }
    return id
  }

  private func readExisting(filePath: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
      let parsed = try? JSONDecoder().decode([String: String].self, from: data)
    else { return nil }
    return parsed["installationId"]
  }
}
