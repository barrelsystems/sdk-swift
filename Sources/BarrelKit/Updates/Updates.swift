import AppKit
import Foundation

@MainActor
struct RuntimeEnvironment {
  var hostBundle: Bundle = .main
  var dataDirectory: URL?
  var makeAdapter: (Bundle, BufferedFactsStore) -> SparkleUpdaterAdapter = {
    SparkleUpdaterAdapter(hostBundle: $0, bufferedFactsStore: $1)
  }
  var writeDebugLog: @Sendable (String) -> Void = { print("[barrel-kit] \($0)") }
  var scheduleCadence: @MainActor (CadenceParams) -> CadenceTicker = startCadence
}

/// Current update status, subscriptions and manual lifecycle controls.
@MainActor
public final class Updates {
  var hostControl: HostControl?
  private var lastKnownUpdateEligibility: Updates.Eligibility?

  private var listeners: [UUID: (Status) -> Void] = [:]
  private var pendingDownload: CheckedContinuation<Void, Error>?

  private var actionTask: Task<Void, Error>?
  private var termination: Task<Void, Never>?

  /// `state` defaults to `.idle` and `eligibility`/`lastError` are `nil`
  /// before `initialize()` resolves.
  func snapshot() -> Status {
    Status(
      state: adapter?.getUpdateState() ?? .idle,
      eligibility: lastKnownUpdateEligibility,
      lastError: adapter?.getLastUpdateError())
  }

  /// Delivers a complete snapshot immediately and after changes.
  public func subscribe(_ listener: @escaping (Status) -> Void) -> Subscription {
    let id = UUID()
    listeners[id] = listener
    listener(snapshot())
    return Subscription { [weak self] in self?.listeners.removeValue(forKey: id) }
  }

  /// Resolves once the download genuinely finishes (`.downloaded`), throws
  /// `.cancelled`/`.failed` if it doesn't, and throws `.held` without
  /// starting anything if a fresh pre-action check denies it.
  public func download() async throws {
    try await runAction { try await self.downloadAvailableUpdate() }
  }

  /// Completes at native installer handoff if the process survives.
  public func apply() async throws {
    try await runAction { try await self.applyDownloadedUpdate() }
  }

  private func runAction(_ operation: @escaping @MainActor () async throws -> Void) async throws {
    guard actionTask == nil else { throw ActionError.alreadyInProgress }

    let task = Task { try await operation() }
    actionTask = task
    defer { actionTask = nil }
    try await task.value
  }

  private func downloadAvailableUpdate() async throws {
    guard let adapter, let hostControl else { throw ActionError.notReady }
    guard case .available = adapter.getUpdateState() else { throw ActionError.noUpdateAvailable }

    let proceeded = await hostControl.downloadUpdate()
    guard proceeded else { throw ActionError.held }

    if let outcome = terminalDownloadOutcome(
      adapter.getUpdateState(), lastError: adapter.getLastUpdateError)
    {
      try outcome.get()
      return
    }

    try await withCheckedThrowingContinuation { continuation in
      pendingDownload = continuation
    }
  }

  /// Completes at native installer handoff if the process survives; it cannot confirm a
  /// successful relaunch.
  private func applyDownloadedUpdate() async throws {
    guard let adapter, let hostControl else { throw ActionError.notReady }
    guard case .downloaded = adapter.getUpdateState() else {
      throw ActionError.nothingDownloadedYet
    }

    let proceeded = await hostControl.applyUpdate()
    guard proceeded else { throw ActionError.held }
    if case .failed = adapter.getUpdateState() {
      throw ActionError.failed(adapter.getLastUpdateError() ?? fallbackFailure())
    }
  }

  // MARK: - Internal wiring, called only from `BarrelKit`.

  func fireStateChanged(_ state: Updates.State) {
    publishStatus()
    resolvePendingDownloadIfTerminal(state)
  }

  func fireEligibilityChanged(_ eligibility: Updates.Eligibility) {
    lastKnownUpdateEligibility = eligibility
    publishStatus()
  }

  private func publishStatus() {
    let status = snapshot()
    for listener in Array(listeners.values) { listener(status) }
  }

  private func resolvePendingDownloadIfTerminal(_ state: Updates.State) {
    guard let waiter = pendingDownload,
      let outcome = terminalDownloadOutcome(
        state, lastError: { self.adapter?.getLastUpdateError() })
    else { return }
    pendingDownload = nil
    switch outcome {
    case .success: waiter.resume()
    case .failure(let error): waiter.resume(throwing: error)
    }
  }

  private let environment: RuntimeEnvironment
  private var initialization: Task<Void, Never>?
  private var cadence: CadenceTicker?

  init(environment: RuntimeEnvironment = RuntimeEnvironment()) { self.environment = environment }

  private var initialized = false
  private var debugLog: (@Sendable (String) -> Void)?
  var adapter: SparkleUpdaterAdapter?
  let bufferedFactsStore = BufferedFactsStore()
  let installationIdStore = InstallationIdStore()
  private var trustedKeyStore = TrustedKeyStore()
  private var versionExpectationStore = VersionExpectationStore()

  func initialize(_ config: InitConfig) throws {
    if initialized {
      debugLog?("init() called again -- ignored, the SDK is already running")
      return
    }

    if config.credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw BarrelConfigError("Barrel: init() requires a non-empty `credential`.")
    }
    if let interval = config.updates.checkInInterval, !interval.isFinite {
      throw BarrelConfigError("Barrel: `checkInInterval` must be finite.")
    }

    if let holdCacheMaxAge = config.updates.holdCacheMaxAge, holdCacheMaxAge > maxHoldCacheMaxAge {
      throw BarrelConfigError("Barrel: `holdCacheMaxAge` must not exceed 7 days.")
    }

    initialized = true
    if config.debug {
      debugLog = environment.writeDebugLog
    } else {
      debugLog = nil
    }

    let baseURL = config.baseURL ?? defaultBaseURL
    let checkInInterval = config.updates.checkInInterval ?? defaultIntervalSeconds
    let autoDownload = config.updates.autoDownload
    let holdCacheMaxAge = config.updates.holdCacheMaxAge ?? defaultHoldCacheMaxAge

    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let bundleId = Bundle.main.bundleIdentifier ?? "barrel-kit"
    let dataDir = environment.dataDirectory ?? appSupport.appendingPathComponent(bundleId)
    let installationIdPath = dataDir.appendingPathComponent("barrel-installation.json").path
    let bufferedFactsPath = dataDir.appendingPathComponent("barrel-buffered-facts.json").path
    let trustedKeyPath = dataDir.appendingPathComponent("barrel-trusted-key.json").path
    let versionExpectationPath = dataDir.appendingPathComponent("barrel-version-expectation.json")
      .path

    initialization = Task { [self] in
      let installationId = await installationIdStore.getOrCreate(filePath: installationIdPath)
      await bufferedFactsStore.configure(filePath: bufferedFactsPath)
      _ = await trustedKeyStore.getOrCreate(
        filePath: trustedKeyPath, builtInKeyPEM: publicEd25519KeyPEM)
      await checkVersionExpectation(filePath: versionExpectationPath)
      let newAdapter = environment.makeAdapter(environment.hostBundle, bufferedFactsStore)
      await newAdapter.hydrateLastErrorFromBufferedFacts()
      if let updateFeedURL = config.updates.updateFeedURL {
        newAdapter.setFeedURL(updateFeedURL)
      }

      let connection = BackendConnection(
        baseURL: baseURL, credential: config.credential, installationId: installationId)

      adapter = newAdapter
      publishStatus()

      newAdapter.onStateChange { [weak self] state in
        self?.fireStateChanged(state)
        if case .available = state, autoDownload {
          Task { [weak self] in try? await self?.download() }
        }
      }
      newAdapter.onUpdateError { [weak self] _ in self?.publishStatus() }
      let newHostControl = HostControl(
        params: HostControlParams(
          connection: connection,
          getTrustedKeyPEM: { [self] in await self.trustedKeyStore.current() ?? publicEd25519KeyPEM
          },
          adapter: newAdapter,
          recordVersionExpectation: { [self] version in
            await self.versionExpectationStore.set(
              filePath: versionExpectationPath, version: version)
          },
          clearVersionExpectation: { [self] in
            await self.versionExpectationStore.clear(filePath: versionExpectationPath)
          },
          completeDeferredTermination: {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
          },
          syncApplyingState: { [weak self] in await self?.cadence?.syncBeforeApply() },
          log: debugLog,
          onEligibility: { [weak self] eligibility in self?.fireEligibilityChanged(eligibility) }))
      hostControl = newHostControl

      cadence = environment.scheduleCadence(
        CadenceParams(
          connection: connection,
          checkInInterval: checkInInterval, sdkVersion: sdkVersion, channel: config.updates.channel,
          attributes: config.updates.attributes,
          retryInstallationPersistence: { [self] in
            await self.installationIdStore.retryPersistence(filePath: installationIdPath)
          },
          log: debugLog,
          getUpdateState: { newAdapter.getReportableUpdateState() },
          getStateRevision: { newAdapter.getReportableStateRevision() },
          getBufferedFacts: { await self.bufferedFactsStore.snapshot() },
          clearBufferedFacts: { sent in await self.bufferedFactsStore.clear(sent: sent) },
          checkForUpdates: { newAdapter.checkForUpdates() },
          onEligibilityResponse: { [self] response in
            guard let response else { return }  // fail open -- keep the last-known decision
            let trustedKeyPEM = await self.trustedKeyStore.current() ?? publicEd25519KeyPEM
            let parsed = verifyAndParseUpdateEligibility(response, publicKeyPEM: trustedKeyPEM)
            if let parsed { self.fireEligibilityChanged(parsed) }
            debugLog?(
              parsed != nil
                ? "update eligibility: verified and updated"
                : "update eligibility: verification failed")
            await self.trustedKeyStore.applyRotationIfPresent(response)
          },
          getUpdateEligibility: { [self] in self.snapshot().eligibility },
          holdCacheMaxAge: holdCacheMaxAge))

      // Applying uses the explicitly awaited HostControl path; scheduling it
      // here too would race that sync for the debounce window.
      newAdapter.onReportableStateChange { [weak self] state in
        if case .applying = state { return }
        Task { await self?.cadence?.stateChanged() }
      }
    }
  }

  func ready() async { await initialization?.value }

  func checkNow() async {
    await ready()
    await cadence?.tick()
    await waitForActions()
  }

  func stopCadence() async { await cadence?.stop() }
  func cadenceIsChecking() async -> Bool { await cadence?.isChecking() ?? false }
  func cadenceIntervalMs() async -> Double? { await cadence?.intervalMs() }

  func waitForActions() async {
    await Task.yield()
    _ = try? await actionTask?.value
    await termination?.value
    await hostControl?.settled()
  }

  /// Resolves what the previous session's apply attempt, if any,
  /// expected to be running by now against what's actually running, then
  /// clears the marker either way so this only ever fires once per attempt.
  private func checkVersionExpectation(filePath: String) async {
    guard let expectedVersion = await versionExpectationStore.read(filePath: filePath) else {
      return
    }

    let runningVersion = collectEnvironment().observedVersion
    if expectedVersion != runningVersion {
      let (failure, _) = buildFailureState(
        platform: "version-check", failureMode: .applyNotConfirmed, phase: .install,
        platformCode: "expected \(expectedVersion), running \(runningVersion)")
      await bufferedFactsStore.recordUpdateError(failure)
    }
    await versionExpectationStore.clear(filePath: filePath)
  }

  /// Call from the host app's own `NSApplicationDelegate.applicationShouldTerminate(_:)`
  /// -- macOS gives a library no way to intercept app termination on its own,
  /// unlike Electron's transparent `before-quit` event.
  public func applicationShouldTerminate() -> Bool {
    guard case .downloaded = adapter?.getUpdateState() else { return true }
    if termination == nil {
      let existingAction = actionTask
      termination = Task {
        _ = try? await existingAction?.value
        await hostControl?.applyUpdateForTermination()
      }
    }
    return false
  }
}

private func fallbackFailure() -> Updates.Failure {
  Updates.Failure(
    phase: .install, failureMode: .unknown, title: "Update failed", platform: "sparkle",
    platformCode: "unknown")
}

private func terminalDownloadOutcome(
  _ state: Updates.State, lastError: () -> Updates.Failure?
) -> Result<Void, Error>? {
  switch state {
  case .downloaded: return .success(())
  case .updateCancelled: return .failure(Updates.ActionError.cancelled)
  case .failed:
    let failure =
      lastError()
      ?? Updates.Failure(
        phase: .download, failureMode: .unknown, title: "Download failed", platform: "sparkle",
        platformCode: "unknown")
    return .failure(Updates.ActionError.failed(failure))
  default: return nil
  }
}
