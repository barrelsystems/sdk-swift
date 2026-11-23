import CryptoKit
import Foundation

/// An Ed25519 SubjectPublicKeyInfo DER encoding is always exactly this fixed
/// 12-byte prefix (SEQUENCE/OID 1.3.101.112/BIT STRING header) followed by the
/// 32 raw key bytes -- CryptoKit only accepts the raw form, not PEM/DER.
private let ed25519SPKIPrefixLength = 12

func ed25519PublicKey(fromPEM pem: String) -> Curve25519.Signing.PublicKey? {
  let body =
    pem
    .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
    .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters),
    der.count == ed25519SPKIPrefixLength + 32
  else { return nil }

  return try? Curve25519.Signing.PublicKey(rawRepresentation: der.suffix(32))
}

/// Verifies the raw `updateEligibility` byte string's Ed25519 signature via
/// CryptoKit, then parses it. Any failure fails open, returning `nil`.
func verifyAndParseUpdateEligibility(_ response: CheckInResponse, publicKeyPEM: String) -> Updates
  .Eligibility?
{
  guard let publicKey = ed25519PublicKey(fromPEM: publicKeyPEM),
    let eligibilityData = response.updateEligibility.data(using: .utf8),
    let signatureData = Data(base64Encoded: response.signature)
  else { return nil }

  guard publicKey.isValidSignature(signatureData, for: eligibilityData) else { return nil }

  return try? JSONDecoder().decode(Updates.Eligibility.self, from: eligibilityData)
}
