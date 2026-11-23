private let fnvOffsetBasis: UInt32 = 0x811c_9dc5
private let fnvPrime: UInt32 = 0x0100_0193

private func fnv1a(_ input: String) -> UInt32 {
  var hash = fnvOffsetBasis
  for byte in input.utf8 {
    hash ^= UInt32(byte)
    hash = hash.multipliedReportingOverflow(by: fnvPrime).partialValue
  }
  return hash
}

/// Deterministic per-installation jitter fraction, fixed for the installation's
/// lifetime: magnitude 10-15%, sign derived from the same hash so it never needs
/// separate storage.
func computeJitterFraction(installationId: String) -> Double {
  let hash = fnv1a(installationId)
  let sign: Double = (hash & 1) == 0 ? 1 : -1
  let magnitude = 0.1 + Double((hash >> 1) % 1000) / 1000 / 20  // 0.10..0.15
  return sign * magnitude
}
