import Foundation

struct HostControlParams: Sendable {
  var connection: BackendConnection
  var autoDownload: Bool
  var getTrustedKeyPEM: @Sendable () async -> String
  var adapter: SparkleUpdaterAdapter
  /// Called with the version about to be applied, immediately before every
  /// `quitAndInstall()` call -- the version-expectation marker a later
  /// startup compares against to confirm the apply actually landed.
  var recordVersionExpectation: @Sendable (String) async -> Void
  /// Called when this session's own apply attempt already failed and was
  /// classified -- clears the marker above so the next startup doesn't
  /// also report it as an unexplained mismatch.
  var clearVersionExpectation: @Sendable () async -> Void
  var log: (@Sendable (String) -> Void)?
  var session: URLSession = .shared
}

/// Gates every download and apply on a fresh `pre-action-check`, not just the
/// cadence's own 30-minute Policy -- a Hold placed since the last check-in
/// must still land in time to stop either action.
@MainActor
final class HostControl {
  private let params: HostControlParams
  // Set right before quitAndInstall(), so a `.failed` transition that
  // follows it synchronously is known to be this same apply attempt.
  private var awaitingApplyOutcome = false
  private var stateChange: Task<Void, Never>?

  init(params: HostControlParams) {
    self.params = params
    params.adapter.onStateChange { [weak self] state in
      self?.stateChange = Task { await self?.handleStateChange(state) }
    }
  }

  func settled() async { await stateChange?.value }

  private func canProceed(stage: PreActionStage) async -> Bool {
    let policy = await checkPreAction(
      PreActionCheckParams(
        connection: params.connection,
        stage: stage, trustedKeyPEM: await params.getTrustedKeyPEM(), log: params.log, session: params.session))
    if case .held = policy { return false }
    return true
  }

  private func attemptDownload() async {
    if await canProceed(stage: .preDownload) {
      params.adapter.downloadUpdate()
    }
  }

  private func handleStateChange(_ state: AdapterState) async {
    if case .available = state, params.autoDownload {
      await attemptDownload()
    }
    if case .failed = state, awaitingApplyOutcome {
      awaitingApplyOutcome = false
      await params.clearVersionExpectation()
    }
  }

  /// Host-triggered earlier download, for a host that set `autoDownload`
  /// off. A no-op, not a throw, before an update is actually available --
  /// there's nothing yet to download.
  func downloadUpdate() async {
    guard case .available = params.adapter.getAdapterState() else { return }
    await attemptDownload()
  }

  /// Host-triggered earlier apply, ahead of the natural-quit default. A
  /// no-op, not a throw, before anything has actually downloaded -- there's
  /// nothing yet to apply.
  func applyUpdate() async {
    guard case .downloaded = params.adapter.getAdapterState() else { return }
    if await canProceed(stage: .preApply) {
      if let version = params.adapter.getTargetVersion() {
        await params.recordVersionExpectation(version)
        awaitingApplyOutcome = true
      }
      params.adapter.quitAndInstall()
    }
  }
}
