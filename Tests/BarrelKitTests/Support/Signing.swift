import CryptoKit
import Foundation

func testPublicKeyPEM(fromRawEd25519PublicKey raw: Data) -> String {
  let prefix: [UInt8] = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]
  return
    "-----BEGIN PUBLIC KEY-----\n\((Data(prefix) + raw).base64EncodedString())\n-----END PUBLIC KEY-----\n"
}

func signedEligibilityBody(type: String, signedBy key: Curve25519.Signing.PrivateKey) throws
  -> String
{
  let value = #"{"type":"\#(type)","issuedAt":"2026-01-01T00:00:00Z","environment":"production"}"#
  let signature = try key.signature(for: Data(value.utf8)).base64EncodedString()
  let body: [String: Any] = [
    "protocolVersion": 1, "updateEligibility": value, "signature": signature,
  ]
  return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
}
