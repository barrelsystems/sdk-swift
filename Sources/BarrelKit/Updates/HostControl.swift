import Foundation

struct HostControlParams: Sendable {
  var connection: BackendConnection
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
  /// Reply to an already-deferred application quit when a fresh check denies installation.
  var completeDeferredTermination: @Sendable @MainActor () -> Void
  /// Await after marking applying and before the native relaunch can
  /// terminate the process. Network failure remains fail-open.
  var syncApplyingState: @Sendable () async -> Void
  var log: (@Sendable (String) -> Void)?
  var session: URLSession = .shared
  var onEligibility: (@Sendable @MainActor (Updates.Eligibility) -> Void)? = nil
}

/// Gates every download and apply on a fresh `pre-action-check`, not just the
/// cadence's own 30-minute eligibility decision -- a Hold placed since the
/// last check-in must still land in time to stop either action.
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
    let updateEligibility = await checkPreAction(
      PreActionCheckParams(
        connection: params.connection,
        stage: stage, trustedKeyPEM: await params.getTrustedKeyPEM(), log: params.log,
        session: params.session))
    if let updateEligibility { params.onEligibility?(updateEligibility) }

    if case .held = updateEligibility { return false }
    return true
  }

  /// `true` once `adapter.downloadUpdate()` has actually been told to
  /// proceed -- `false` if a fresh pre-action check held it.
  private func attemptDownload() async -> Bool {
    guard await canProceed(stage: .preDownload) else { return false }
    params.adapter.downloadUpdate()
    return true
  }

  private func handleStateChange(_ state: Updates.State) async {
    if case .failed = state, awaitingApplyOutcome {
      awaitingApplyOutcome = false
      await params.clearVersionExpectation()
    }
  }

  /// A host-triggered download is gated by a fresh eligibility check and its required
  /// lifecycle state.
  func downloadUpdate() async -> Bool {
    guard case .available = params.adapter.getUpdateState() else { return false }
    return await attemptDownload()
  }

  /// Manual apply authorizes the downloaded update; denial does not itself request
  /// application termination.
  func applyUpdate() async -> Bool {
    guard case .downloaded = params.adapter.getUpdateState() else { return false }
    guard await canProceed(stage: .preApply) else { return false }
    await proceedWithApply()
    return true
  }

  /// A denied install must complete the application termination that was already deferred.
  func applyUpdateForTermination() async {
    guard case .downloaded = params.adapter.getUpdateState() else {
      params.completeDeferredTermination()
      return
    }
    if await canProceed(stage: .preApply) {
      await proceedWithApply()
    } else {
      params.completeDeferredTermination()
    }
  }

  // Native installation owns relaunch; only denial needs an explicit reply to the application
  // termination deferral.
  private func proceedWithApply() async {
    if let version = params.adapter.getTargetVersion() {
      await params.recordVersionExpectation(version)
      awaitingApplyOutcome = true
    }
    params.adapter.markApplying()
    await params.syncApplyingState()
    params.adapter.quitAndInstall()
  }
}
