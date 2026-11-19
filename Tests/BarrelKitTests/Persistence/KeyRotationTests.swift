import CryptoKit
import Foundation
import Testing

@testable import BarrelKit

private func pem(fromRawEd25519PublicKey raw: Data) -> String {
  let spkiPrefix: [UInt8] = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]
  let der = Data(spkiPrefix) + raw
  return "-----BEGIN PUBLIC KEY-----\n\(der.base64EncodedString())\n-----END PUBLIC KEY-----\n"
}

private func baseResponse(
  nextPublicKeyPem: String? = nil, nextPublicKeySignature: String? = nil
) -> CheckInResponse {
  CheckInResponse(
    protocolVersion: 1, policy: "{}", signature: "sig",
    nextPublicKeyPem: nextPublicKeyPem, nextPublicKeySignature: nextPublicKeySignature)
}

@Suite struct KeyRotationTests {
  @Test func getOrCreateFallsBackToTheBuildTimeDefaultWhenNothingIsCached() async {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/key.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let store = TrustedKeyStore()
    let trusted = await store.getOrCreate(filePath: path, builtInKeyPEM: "built-in-key-pem")
    #expect(trusted == "built-in-key-pem")
  }

  @Test func adoptsARotationValidlySignedByTheCurrentlyTrustedKey() async throws {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/key.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let currentKey = Curve25519.Signing.PrivateKey()
    let nextKey = Curve25519.Signing.PrivateKey()
    let currentPEM = pem(fromRawEd25519PublicKey: currentKey.publicKey.rawRepresentation)
    let nextPEM = pem(fromRawEd25519PublicKey: nextKey.publicKey.rawRepresentation)

    let store = TrustedKeyStore()
    _ = await store.getOrCreate(filePath: path, builtInKeyPEM: currentPEM)

    let signature = try currentKey.signature(for: Data(nextPEM.utf8))
    await store.applyRotationIfPresent(
      baseResponse(nextPublicKeyPem: nextPEM, nextPublicKeySignature: signature.base64EncodedString()))

    #expect(await store.current() == nextPEM)
  }

  @Test func failsOpenRejectingARotationSignedByAKeyOtherThanTheOneCurrentlyTrusted() async throws {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/key.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let currentKey = Curve25519.Signing.PrivateKey()
    let imposterKey = Curve25519.Signing.PrivateKey()
    let nextKey = Curve25519.Signing.PrivateKey()
    let currentPEM = pem(fromRawEd25519PublicKey: currentKey.publicKey.rawRepresentation)
    let nextPEM = pem(fromRawEd25519PublicKey: nextKey.publicKey.rawRepresentation)

    let store = TrustedKeyStore()
    _ = await store.getOrCreate(filePath: path, builtInKeyPEM: currentPEM)

    let signature = try imposterKey.signature(for: Data(nextPEM.utf8))
    await store.applyRotationIfPresent(
      baseResponse(nextPublicKeyPem: nextPEM, nextPublicKeySignature: signature.base64EncodedString()))

    #expect(await store.current() == currentPEM)
  }

  @Test func failsOpenLeavingTheCurrentKeyUntouchedWhenNoRotationFieldsArePresent() async {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/key.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let currentKey = Curve25519.Signing.PrivateKey()
    let currentPEM = pem(fromRawEd25519PublicKey: currentKey.publicKey.rawRepresentation)

    let store = TrustedKeyStore()
    _ = await store.getOrCreate(filePath: path, builtInKeyPEM: currentPEM)
    await store.applyRotationIfPresent(baseResponse())

    #expect(await store.current() == currentPEM)
  }

  @Test func failsOpenRejectingMalformedNextKeyMaterialEvenWithAValidlySignedEnvelope() async throws {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/key.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let currentKey = Curve25519.Signing.PrivateKey()
    let currentPEM = pem(fromRawEd25519PublicKey: currentKey.publicKey.rawRepresentation)
    let malformedKey = "not a real PEM"

    let store = TrustedKeyStore()
    _ = await store.getOrCreate(filePath: path, builtInKeyPEM: currentPEM)

    let signature = try currentKey.signature(for: Data(malformedKey.utf8))
    await store.applyRotationIfPresent(
      baseResponse(nextPublicKeyPem: malformedKey, nextPublicKeySignature: signature.base64EncodedString()))

    #expect(await store.current() == currentPEM)
  }

  @Test func persistsAnAdoptedRotationAndReloadsItAsTrustedOnAFreshInstance() async throws {
    let path = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)/key.json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let currentKey = Curve25519.Signing.PrivateKey()
    let nextKey = Curve25519.Signing.PrivateKey()
    let currentPEM = pem(fromRawEd25519PublicKey: currentKey.publicKey.rawRepresentation)
    let nextPEM = pem(fromRawEd25519PublicKey: nextKey.publicKey.rawRepresentation)

    let first = TrustedKeyStore()
    _ = await first.getOrCreate(filePath: path, builtInKeyPEM: currentPEM)
    let signature = try currentKey.signature(for: Data(nextPEM.utf8))
    await first.applyRotationIfPresent(
      baseResponse(nextPublicKeyPem: nextPEM, nextPublicKeySignature: signature.base64EncodedString()))

    // Simulate a fresh process: a brand-new store, no in-memory cache --
    // only what the first store persisted to disk.
    let second = TrustedKeyStore()
    let resolved = await second.getOrCreate(filePath: path, builtInKeyPEM: "a-different-build-time-default")
    #expect(resolved == nextPEM)
  }

  @Test func failsOpenKeepingTheAdoptedKeyInMemoryWhenPersistenceIsImpossible() async throws {
    let dir = NSTemporaryDirectory() + "barrel-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let blockerFile = dir + "/blocker"
    try Data("not a directory".utf8).write(to: URL(fileURLWithPath: blockerFile))
    let impossiblePath = blockerFile + "/key.json"  // can't create a file under a file

    let currentKey = Curve25519.Signing.PrivateKey()
    let nextKey = Curve25519.Signing.PrivateKey()
    let currentPEM = pem(fromRawEd25519PublicKey: currentKey.publicKey.rawRepresentation)
    let nextPEM = pem(fromRawEd25519PublicKey: nextKey.publicKey.rawRepresentation)

    let store = TrustedKeyStore()
    _ = await store.getOrCreate(filePath: impossiblePath, builtInKeyPEM: currentPEM)
    let signature = try currentKey.signature(for: Data(nextPEM.utf8))
    await store.applyRotationIfPresent(
      baseResponse(nextPublicKeyPem: nextPEM, nextPublicKeySignature: signature.base64EncodedString()))

    #expect(await store.current() == nextPEM)
  }
}
