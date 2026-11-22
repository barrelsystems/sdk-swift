import AppKit
import Foundation

/// The only required call. Silent until this runs, throws synchronously
/// only for invalid config, and is a silent no-op on a second call --
/// every later failure fails open instead of throwing.
@MainActor
public final class BarrelKit {
  public static let shared = BarrelKit()
  private init() {}

  private var initialized = false
  private var lastKnownPolicy: Policy?
  private var debugLog: (@Sendable (String) -> Void)?
  private var adapter: SparkleUpdaterAdapter?
  private var hostControl: HostControl?
  private var bufferedFactsStore = BufferedFactsStore()
  private var installationIdStore = InstallationIdStore()
  private var trustedKeyStore = TrustedKeyStore()
  private var versionExpectationStore = VersionExpectationStore()
  private var pendingStateChangeListeners: [(AdapterState) -> Void] = []

  public func initialize(_ config: InitConfig) throws {
    if initialized {
      debugLog?("init() called again -- ignored, the SDK is already running")
      return
    }

    if config.credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw BarrelConfigError("Barrel: init() requires a non-empty `credential`.")
    }
    if let holdCacheMaxAge = config.holdCacheMaxAge, holdCacheMaxAge > maxHoldCacheMaxAge {
      throw BarrelConfigError("Barrel: `holdCacheMaxAge` must not exceed 7 days.")
    }

    initialized = true
    if config.debug {
      debugLog = { message in print("[barrel-kit] \(message)") }
    } else {
      debugLog = nil
    }

    let baseURL = config.baseURL ?? defaultBaseURL
    let checkInInterval = config.checkInInterval ?? defaultIntervalSeconds
    let autoDownload = config.autoDownload
    let holdCacheMaxAge = config.holdCacheMaxAge ?? defaultHoldCacheMaxAge

    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let bundleId = Bundle.main.bundleIdentifier ?? "barrel-kit"
    let dataDir = appSupport.appendingPathComponent(bundleId)
    let installationIdPath = dataDir.appendingPathComponent("barrel-installation.json").path
    let bufferedFactsPath = dataDir.appendingPathComponent("barrel-buffered-facts.json").path
    let trustedKeyPath = dataDir.appendingPathComponent("barrel-trusted-key.json").path
    let versionExpectationPath = dataDir.appendingPathComponent("barrel-version-expectation.json").path

    Task {
      let installationId = await installationIdStore.getOrCreate(filePath: installationIdPath)
      await bufferedFactsStore.configure(filePath: bufferedFactsPath)
      _ = await trustedKeyStore.getOrCreate(filePath: trustedKeyPath, builtInKeyPEM: publicEd25519KeyPEM)
      await checkVersionExpectation(filePath: versionExpectationPath)
      let newAdapter = SparkleUpdaterAdapter(hostBundle: .main, bufferedFactsStore: bufferedFactsStore)
      if let updateFeedURL = config.updateFeedURL {
        newAdapter.setFeedURL(updateFeedURL)
      }

      let connection = BackendConnection(baseURL: baseURL, credential: config.credential, installationId: installationId)

      adapter = newAdapter
      for listener in pendingStateChangeListeners { newAdapter.onStateChange(listener) }
      pendingStateChangeListeners = []
      hostControl = HostControl(
        params: HostControlParams(
          connection: connection,
          autoDownload: autoDownload,
          getTrustedKeyPEM: { [self] in await self.trustedKeyStore.current() ?? publicEd25519KeyPEM },
          adapter: newAdapter,
          recordVersionExpectation: { [self] version in
            await self.versionExpectationStore.set(filePath: versionExpectationPath, version: version)
          },
          clearVersionExpectation: { [self] in
            await self.versionExpectationStore.clear(filePath: versionExpectationPath)
          },
          log: debugLog))

      startCadence(
        CadenceParams(
          connection: connection,
          checkInInterval: checkInInterval, sdkVersion: sdkVersion, attributes: config.attributes,
          log: debugLog,
          getAdapterState: { newAdapter.getAdapterState() },
          getBufferedFacts: { await self.bufferedFactsStore.snapshot() },
          clearBufferedFacts: { sent in await self.bufferedFactsStore.clear(sent: sent) },
          checkForUpdates: { newAdapter.checkForUpdates() },
          onPolicyResponse: { [self] response in
            guard let response else { return }  // fail open -- keep the last-known Policy
            let trustedKeyPEM = await self.trustedKeyStore.current() ?? publicEd25519KeyPEM
            if let parsed = verifyAndParsePolicy(response, publicKeyPEM: trustedKeyPEM) {
              self.lastKnownPolicy = parsed
            }
            debugLog?(self.lastKnownPolicy != nil ? "policy: verified and updated" : "policy: verification failed")
            await self.trustedKeyStore.applyRotationIfPresent(response)
          },
          getPolicy: { [self] in self.lastKnownPolicy },
          holdCacheMaxAge: holdCacheMaxAge))
    }
  }

  /// Resolves what the previous session's apply attempt, if any,
  /// expected to be running by now against what's actually running, then
  /// clears the marker either way so this only ever fires once per attempt.
  private func checkVersionExpectation(filePath: String) async {
    guard let expectedVersion = await versionExpectationStore.read(filePath: filePath) else { return }

    let runningVersion = collectEnvironment().observedVersion
    if expectedVersion != runningVersion {
      let (failure, _) = buildFailureState(
        platform: "version-check", failureMode: .applyNotConfirmed, phase: .install,
        platformCode: "expected \(expectedVersion), running \(runningVersion)")
      await bufferedFactsStore.recordUpdateError(failure)
    }
    await versionExpectationStore.clear(filePath: filePath)
  }

  /// `nil` before the first successful check-in -- never a synthesized default.
  public func getPolicy() -> Policy? { lastKnownPolicy }

  /// `nil` if nothing has failed this session.
  public func getLastUpdateError() -> UpdateFailure? { adapter?.getLastUpdateError() }

  /// `nil` before `initialize()`'s async setup has resolved.
  public func getAdapterState() -> AdapterState? { adapter?.getAdapterState() }

  /// Fires on every local adapter-state transition, in addition to --
  /// never instead of -- `getAdapterState()`'s own polling. Register
  /// once, at startup; listeners are never removed.
  public func onStateChange(_ listener: @escaping (AdapterState) -> Void) {
    if let adapter {
      adapter.onStateChange(listener)
    } else {
      // Queued until `initialize()`'s async setup creates the adapter.
      pendingStateChangeListeners.append(listener)
    }
  }

  /// A silent no-op if the adapter isn't currently `available`.
  public func downloadUpdate() {
    Task { await hostControl?.downloadUpdate() }
  }

  /// A silent no-op if the adapter hasn't finished `downloaded`-ing yet.
  public func applyUpdate() {
    Task { await hostControl?.applyUpdate() }
  }

  /// Call from the host app's own `NSApplicationDelegate.applicationShouldTerminate(_:)`
  /// -- macOS gives a library no way to intercept app termination on its own,
  /// unlike Electron's transparent `before-quit` event.
  public func applicationShouldTerminate() -> Bool {
    guard case .downloaded = adapter?.getAdapterState() else { return true }
    applyUpdate()
    return false
  }
}
