import Foundation

/// Resolves and maintains the key this SDK currently trusts, including any
/// rotation announcement adopted from a check-in response.
actor TrustedKeyStore {
  private var cachedKeyPEM: String?
  private var filePath: String?
  // Actors are reentrant across an `await` -- without this, a second
  // `applyRotationIfPresent` could run its own guard checks and disk
  // write interleaved with this one's, leaving disk out of sync with
  // whichever call's in-memory update happened to land last.
  private var rotationInFlight: Task<Void, Never>?

  /// Resolves the key in effect at startup: a previously-adopted rotation
  /// cached on disk, or the build-time default otherwise. Call once, before
  /// the first check-in's Policy is verified.
  func getOrCreate(filePath: String, builtInKeyPEM: String) async -> String {
    self.filePath = filePath

    if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
      let parsed = try? JSONDecoder().decode([String: String].self, from: data),
      let publicKeyPEM = parsed["publicKeyPEM"]
    {
      cachedKeyPEM = publicKeyPEM
      return publicKeyPEM
    }

    cachedKeyPEM = builtInKeyPEM
    return builtInKeyPEM
  }

  /// The key currently in effect. `nil` only if called before `getOrCreate`.
  func current() -> String? { cachedKeyPEM }

  /// Verifies a rotation announcement against the key this SDK ALREADY
  /// trusts, never the new key -- a key can only vouch for its own successor.
  func applyRotationIfPresent(_ response: CheckInResponse) async {
    // Wait for any rotation already in flight to fully finish (memory AND
    // disk) before this call reads `cachedKeyPEM` or writes its own --
    // otherwise two overlapping calls could get their disk writes done
    // out of order relative to the in-memory key they end up agreeing on.
    await rotationInFlight?.value

    guard
      let nextPublicKeyPEM = response.nextPublicKeyPem,
      let nextPublicKeySignature = response.nextPublicKeySignature,
      let currentKeyPEM = cachedKeyPEM,
      let currentPublicKey = ed25519PublicKey(fromPEM: currentKeyPEM),
      let signatureData = Data(base64Encoded: nextPublicKeySignature),
      currentPublicKey.isValidSignature(signatureData, for: Data(nextPublicKeyPEM.utf8)),
      ed25519PublicKey(fromPEM: nextPublicKeyPEM) != nil  // validates the new key material parses
    else { return }  // fails open: malformed key material or a bad signature leaves the current key in effect

    cachedKeyPEM = nextPublicKeyPEM
    guard let filePath, let data = try? JSONEncoder().encode(["publicKeyPEM": nextPublicKeyPEM]) else { return }

    let persistTask = Task {
      PersistenceWriter.persist(path: filePath, data: data)
      await PersistenceWriter.waitForPendingWrites()
    }
    rotationInFlight = persistTask
    await persistTask.value
  }
}
