/// Tallies a bug in this SDK's own adapter code, by coarse cause, and
/// swallows it -- never crashes the host or leaks into `Updates.Failure`.
/// Counts only, never a message/stack trace -- see README for why.
@MainActor
enum InternalDefects {
  private static var counts: [String: Int] = [:]

  static func record(_ cause: String) {
    counts[cause, default: 0] += 1
  }

  /// Exposed for the future reporting path and for tests; not public API yet.
  static func counts(for cause: String) -> Int {
    counts[cause, default: 0]
  }
}
