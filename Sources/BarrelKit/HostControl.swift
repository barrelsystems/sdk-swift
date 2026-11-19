import Foundation

struct HostControlParams: Sendable {
  var baseURL: String
  var credential: String
  var installationId: String
  var autoDownload: Bool
  var getTrustedKeyPEM: @Sendable () async -> String
  var adapter: SparkleUpdaterAdapter
  var log: (@Sendable (String) -> Void)?
  var session: URLSession = .shared
}

/// Gates every download and apply on a fresh `pre-action-check`, not just the
/// cadence's own 30-minute Policy -- a Hold placed since the last check-in
/// must still land in time to stop either action.
@MainActor
final class HostControl {
  private let params: HostControlParams

  init(params: HostControlParams) {
    self.params = params
    params.adapter.onStateChange { [weak self] state in
      Task { await self?.handleStateChange(state) }
    }
  }

  private func canProceed(stage: PreActionStage) async -> Bool {
    let policy = await checkPreAction(
      PreActionCheckParams(
        baseURL: params.baseURL, credential: params.credential, installationId: params.installationId,
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
      params.adapter.quitAndInstall()
    }
  }
}
