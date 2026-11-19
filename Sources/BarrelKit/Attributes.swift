private let maxAttributeKeys = 20
private let maxAttributeValueBytes = 256

/// Enforces the wire protocol's bounds: at most 20 keys, each value <=256 UTF-8 bytes.
func boundAttributes(_ attributes: [String: String]) -> [String: String] {
  var bounded: [String: String] = [:]

  for (key, value) in attributes.prefix(maxAttributeKeys) {
    bounded[key] = truncateToByteLimit(value, maxBytes: maxAttributeValueBytes)
  }

  return bounded
}

private func truncateToByteLimit(_ value: String, maxBytes: Int) -> String {
  var encoded = Array(value.utf8)
  if encoded.count <= maxBytes { return value }

  while encoded.count > maxBytes {
    encoded.removeLast()
  }
  // Back off further if the cut landed mid-codepoint.
  while !encoded.isEmpty, String(decoding: encoded, as: UTF8.self).utf8.count != encoded.count {
    encoded.removeLast()
  }
  return String(decoding: encoded, as: UTF8.self)
}
