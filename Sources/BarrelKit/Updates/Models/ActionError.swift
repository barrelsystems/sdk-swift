import Foundation

extension Updates {
  /// A manual action could not complete, with its native failure classification when available.
  public enum ActionError: Error, LocalizedError, Sendable, Equatable {
    /// Nothing is `.available` to download yet.
    case noUpdateAvailable
    /// Nothing has finished downloading yet to apply.
    case nothingDownloadedYet
    /// A download is already in flight.
    case alreadyInProgress
    /// A fresh pre-action check held this action.
    case held
    /// The download was cancelled before finishing.
    case cancelled
    /// The download failed after starting.
    case failed(Updates.Failure)
    /// Called before `BarrelKit.initialize()`'s async setup has resolved.
    case notReady

    public var errorDescription: String? {
      switch self {
      case .noUpdateAvailable: return "No update is available to download."
      case .nothingDownloadedYet: return "Nothing has finished downloading yet to apply."
      case .alreadyInProgress: return "A download is already in progress."
      case .held: return "This action is currently held by a verified eligibility decision."
      case .cancelled: return "The download was cancelled."
      case .failed(let failure): return failure.title
      case .notReady: return "Barrel has not finished initializing yet."
      }
    }
  }

}
