import Foundation

extension Updates {
  /// Complete local status; idle and absent eligibility/error before asynchronous
  /// initialization.
  public struct Status: Sendable, Encodable {
    public let state: Updates.State
    /// `nil` before the first verified check-in response.
    public let eligibility: Updates.Eligibility?
    /// `nil` if nothing has failed this session.
    public let lastError: Updates.Failure?
  }

  /// Returned by `subscribe`, call `remove()` when the
  /// listener is no longer needed. Removing twice is a silent no-op.
  @MainActor
  public final class Subscription {
    private var onRemove: (() -> Void)?
    init(onRemove: @escaping () -> Void) { self.onRemove = onRemove }
    public func remove() {
      onRemove?()
      onRemove = nil
    }
  }

}
