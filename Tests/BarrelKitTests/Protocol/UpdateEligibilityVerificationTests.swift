import CryptoKit
import Foundation
import Testing

@testable import BarrelKit

@Suite struct UpdateEligibilityVerificationTests {
  @Test func parsesTheRealEmbeddedProductionKey() {
    #expect(ed25519PublicKey(fromPEM: publicEd25519KeyPEM) != nil)
  }

  @Test func rejectsGarbagePEM() {
    #expect(
      ed25519PublicKey(
        fromPEM: "-----BEGIN PUBLIC KEY-----\nbm90LWEta2V5\n-----END PUBLIC KEY-----\n") == nil)
  }

  @Test func acceptsAValidlySignedUpdateEligibility() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let pem = testPublicKeyPEM(fromRawEd25519PublicKey: privateKey.publicKey.rawRepresentation)
    let updateEligibilityJSON =
      #"{"type":"unrestricted","issuedAt":"2026-01-01T00:00:00Z","environment":"production"}"#
    let signature = try privateKey.signature(for: Data(updateEligibilityJSON.utf8))

    let response = CheckInResponse(
      protocolVersion: 1, updateEligibility: updateEligibilityJSON,
      signature: signature.base64EncodedString())
    let updateEligibility = verifyAndParseUpdateEligibility(response, publicKeyPEM: pem)
    #expect(
      updateEligibility
        == .unrestricted(issuedAt: "2026-01-01T00:00:00Z", environment: "production"))
  }

  @Test func rejectsAnUpdateEligibilitySignedByADifferentKey() throws {
    let trustedKey = Curve25519.Signing.PrivateKey()
    let attackerKey = Curve25519.Signing.PrivateKey()
    let trustedPEM = testPublicKeyPEM(
      fromRawEd25519PublicKey: trustedKey.publicKey.rawRepresentation)
    let updateEligibilityJSON =
      #"{"type":"unrestricted","issuedAt":"2026-01-01T00:00:00Z","environment":"production"}"#
    let signature = try attackerKey.signature(for: Data(updateEligibilityJSON.utf8))

    let response = CheckInResponse(
      protocolVersion: 1, updateEligibility: updateEligibilityJSON,
      signature: signature.base64EncodedString())
    #expect(verifyAndParseUpdateEligibility(response, publicKeyPEM: trustedPEM) == nil)
  }

  @Test func rejectsATamperedUpdateEligibilityBody() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let pem = testPublicKeyPEM(fromRawEd25519PublicKey: privateKey.publicKey.rawRepresentation)
    let signedJSON =
      #"{"type":"unrestricted","issuedAt":"2026-01-01T00:00:00Z","environment":"production"}"#
    let signature = try privateKey.signature(for: Data(signedJSON.utf8))
    let tamperedJSON =
      #"{"type":"eligible","issuedAt":"2026-01-01T00:00:00Z","environment":"production"}"#

    let response = CheckInResponse(
      protocolVersion: 1, updateEligibility: tamperedJSON,
      signature: signature.base64EncodedString())
    #expect(verifyAndParseUpdateEligibility(response, publicKeyPEM: pem) == nil)
  }
}
