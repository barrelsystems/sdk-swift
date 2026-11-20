import CryptoKit
import Foundation
import Testing

@testable import BarrelKit

private func pem(fromRawEd25519PublicKey raw: Data) -> String {
  let spkiPrefix: [UInt8] = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]
  let der = Data(spkiPrefix) + raw
  return "-----BEGIN PUBLIC KEY-----\n\(der.base64EncodedString())\n-----END PUBLIC KEY-----\n"
}

@Suite struct PolicyTests {
  @Test func parsesTheRealEmbeddedProductionKey() {
    #expect(ed25519PublicKey(fromPEM: publicEd25519KeyPEM) != nil)
  }

  @Test func rejectsGarbagePEM() {
    #expect(ed25519PublicKey(fromPEM: "-----BEGIN PUBLIC KEY-----\nbm90LWEta2V5\n-----END PUBLIC KEY-----\n") == nil)
  }

  @Test func acceptsAValidlySignedPolicy() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let pem = pem(fromRawEd25519PublicKey: privateKey.publicKey.rawRepresentation)
    let policyJSON = #"{"type":"current","issuedAt":"2026-01-01T00:00:00Z","environment":"production"}"#
    let signature = try privateKey.signature(for: Data(policyJSON.utf8))

    let response = CheckInResponse(
      protocolVersion: 1, policy: policyJSON, signature: signature.base64EncodedString())
    let policy = verifyAndParsePolicy(response, publicKeyPEM: pem)
    #expect(policy == .current(issuedAt: "2026-01-01T00:00:00Z", environment: "production"))
  }

  @Test func rejectsAPolicySignedByADifferentKey() throws {
    let trustedKey = Curve25519.Signing.PrivateKey()
    let attackerKey = Curve25519.Signing.PrivateKey()
    let trustedPEM = pem(fromRawEd25519PublicKey: trustedKey.publicKey.rawRepresentation)
    let policyJSON = #"{"type":"current","issuedAt":"2026-01-01T00:00:00Z","environment":"production"}"#
    let signature = try attackerKey.signature(for: Data(policyJSON.utf8))

    let response = CheckInResponse(
      protocolVersion: 1, policy: policyJSON, signature: signature.base64EncodedString())
    #expect(verifyAndParsePolicy(response, publicKeyPEM: trustedPEM) == nil)
  }

  @Test func rejectsATamperedPolicyBody() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let pem = pem(fromRawEd25519PublicKey: privateKey.publicKey.rawRepresentation)
    let signedJSON = #"{"type":"current","issuedAt":"2026-01-01T00:00:00Z","environment":"production"}"#
    let signature = try privateKey.signature(for: Data(signedJSON.utf8))
    let tamperedJSON = #"{"type":"updateEligible","issuedAt":"2026-01-01T00:00:00Z","environment":"production"}"#

    let response = CheckInResponse(
      protocolVersion: 1, policy: tamperedJSON, signature: signature.base64EncodedString())
    #expect(verifyAndParsePolicy(response, publicKeyPEM: pem) == nil)
  }
}
