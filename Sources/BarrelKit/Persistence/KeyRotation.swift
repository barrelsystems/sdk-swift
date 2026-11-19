import Foundation

/// Resolves and maintains the key this SDK currently trusts, including any
/// rotation announcement adopted from a check-in response.
actor TrustedKeyStore {
  private var cachedKeyPEM: String?
  private var filePath: String?

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
    await DiskStore.persist(path: filePath, data: data)
  }
}
