import AppKit
import Foundation

let defaultIntervalSeconds: TimeInterval = 30 * 60
let minIntervalSeconds: TimeInterval = 15 * 60
/// Keeps stuck-tier escalation meaningfully faster than the going-dark
/// window regardless of configured interval.
let maxIntervalSeconds: TimeInterval = 2 * 60 * 60
let defaultHoldCacheMaxAge: TimeInterval = 24 * 60 * 60
let maxHoldCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60
let sdkVersion = "0.1.0"
/// How long a burst of reportable adapter-state transitions (chiefly rapid
/// download-progress updates) collapses into a single outgoing check-in.
let defaultStateSyncDebounceSeconds: TimeInterval = 5

struct CadenceParams: Sendable {
  var connection: BackendConnection
  var checkInInterval: TimeInterval
  var sdkVersion: String
  var channel: String
  var attributes: [String: String]
  var retryInstallationPersistence: @Sendable () async -> Void
  var log: (@Sendable (String) -> Void)?
  var getUpdateState: @MainActor () -> Updates.State
  var getStateRevision: (@MainActor () -> UInt64)? = nil
  var getBufferedFacts: @Sendable () async -> [BufferedFact]
  /// Called only once ingestion ACKs the check-in that carried `sent` -- never optimistically.
  var clearBufferedFacts: @Sendable ([BufferedFact]) async -> Void
  var checkForUpdates: @MainActor () -> Void
  var onEligibilityResponse: @MainActor (CheckInResponse?) async -> Void
  var getUpdateEligibility: @MainActor () -> Updates.Eligibility?
  var holdCacheMaxAge: TimeInterval
  /// Overridable only for tests -- production always uses the real 5s window.
  var stateSyncDebounceSeconds: TimeInterval = defaultStateSyncDebounceSeconds
  var session: URLSession = .shared
}

/// Honor only verified Holds within both their declared expiry and the configured maximum
/// cache lifetime.
func updateEligibilityHoldsTheVendorCheck(
  _ updateEligibility: Updates.Eligibility?, holdCacheMaxAge: TimeInterval, now: Date = Date()
)
  -> Bool
{
  guard case .held(let issuedAt, _, _, let until) = updateEligibility else { return false }
  guard let issuedAtDate = parseISO8601(issuedAt) else { return false }
  if now.timeIntervalSince(issuedAtDate) > holdCacheMaxAge { return false }
  if let until, let untilDate = parseISO8601(until), now > untilDate { return false }
  return true
}

private func parseISO8601(_ string: String) -> Date? {
  let withFractional = ISO8601DateFormatter()
  withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return withFractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}

/// Checks in on launch, then on a jittered interval, plus on
/// resume-from-sleep and foreground-activation.
@MainActor
@discardableResult
func startCadence(_ params: CadenceParams) -> CadenceTicker {
  if params.checkInInterval < minIntervalSeconds {
    params.log?(
      "cadence: requested interval \(params.checkInInterval)s is below the \(minIntervalSeconds)s floor, clamped"
    )
  }
  if params.checkInInterval > maxIntervalSeconds {
    params.log?(
      "cadence: requested interval \(params.checkInInterval)s is above the \(maxIntervalSeconds)s ceiling, clamped"
    )
  }

  let ticker = CadenceTicker(params: params)
  // Scheduling and wire reporting share the same clamped nominal interval.
  let jitterFraction = computeJitterFraction(installationId: params.connection.installationId)
  let jitteredInterval = ticker.clampedIntervalSeconds * (1 + jitterFraction)

  let bindings = CadenceBindings(interval: jitteredInterval, ticker: ticker)
  Task {
    await ticker.attach(bindings: bindings)
    await ticker.tick()
  }

  return ticker
}

@MainActor
final class CadenceBindings {
  let intervalMs: Double
  private var timer: Timer?
  private var wakeObserver: NSObjectProtocol?
  private var activeObserver: NSObjectProtocol?

  init(interval: TimeInterval, ticker: CadenceTicker) {
    intervalMs = interval * 1000
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      Task { await ticker.tick() }
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in Task { await ticker.tick() } }
    activeObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in Task { await ticker.tick() } }
  }

  func stop() {
    timer?.invalidate()
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    timer = nil
    wakeObserver = nil
    activeObserver = nil
  }
}

/// The three fields of a leading+trailing debounce window always change
/// together -- one state, not three independently-tracked flags.
private struct DebounceWindow {
  var task: Task<Void, Never>?
  // `true` from the moment a burst's first event fires until the quiet
  // window closes with nothing left pending.
  var isActive = false
  var trailingSyncPending = false

  mutating func cancel() {
    task?.cancel()
    task = nil
    isActive = false
    trailingSyncPending = false
  }
}

actor CadenceTicker {
  private let params: CadenceParams
  // The single source of truth for this installation's clamped cadence --
  // computed once here, read by `startCadence`'s jitter and by every
  // check-in's own `checkInIntervalMs`, so the two can never drift apart.
  nonisolated let clampedIntervalSeconds: TimeInterval
  private var inFlight = false
  private var lastAttemptedRevision: UInt64?
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var bindings: CadenceBindings?
  private var stopped = false
  private var debounceWindow = DebounceWindow()

  func attach(bindings: CadenceBindings) async {
    if stopped { await bindings.stop() } else { self.bindings = bindings }
  }

  func stop() async {
    stopped = true
    releaseIdleWaiters()
    debounceWindow.cancel()
    await bindings?.stop()
    bindings = nil
  }

  func isChecking() -> Bool { inFlight }

  func intervalMs() -> Double? { bindings?.intervalMs }

  // Applying must be attempted before relaunch, even during a debounce
  // window or an unrelated request. Its HTTP timeout bounds the wait.
  func syncBeforeApply() async {
    if stopped { return }

    await performCheckIn()
  }

  init(params: CadenceParams) {
    self.params = params
    self.clampedIntervalSeconds = min(
      max(params.checkInInterval, minIntervalSeconds), maxIntervalSeconds)
  }

  // A tick that fires while the previous one is still in flight is
  // skipped, not queued -- overlapping attempts are impossible.
  func tick() async {
    if stopped { return }

    if inFlight {
      params.log?("cadence: tick skipped, a check-in is already in flight")
      return
    }
    inFlight = true
    defer { finishCheckIn() }

    await params.retryInstallationPersistence()

    // The vendor update-feed check piggybacks on this same cadence but
    // MUST NOT run while held -- a Hold gates the check itself, not just
    // the download/apply actions downstream of it.
    let updateEligibility = await MainActor.run { params.getUpdateEligibility() }
    if !updateEligibilityHoldsTheVendorCheck(
      updateEligibility, holdCacheMaxAge: params.holdCacheMaxAge)
    {
      await MainActor.run { params.checkForUpdates() }
    }

    await performCheckIn()
  }

  /// Sync the first reportable transition immediately, then flush the
  /// latest state after five quiet seconds. Vendor feed checks stay on
  /// the periodic cadence.
  func stateChanged() async {
    if stopped { return }

    let needsLeadingSync = !debounceWindow.isActive
    if needsLeadingSync {
      debounceWindow.isActive = true
      debounceWindow.trailingSyncPending = false
    } else {
      debounceWindow.trailingSyncPending = true
    }

    // Resets on every call, classic debounce-window shape: the window
    // closes `stateSyncDebounceSeconds` after the *last* event, not the first.
    debounceWindow.task?.cancel()
    let debounceSeconds = params.stateSyncDebounceSeconds
    debounceWindow.task = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(debounceSeconds * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.closeDebounceWindow()
    }

    if needsLeadingSync { await syncNow() }
  }

  private func closeDebounceWindow() async {
    if stopped { return }

    debounceWindow.isActive = false
    let needsTrailingSync = debounceWindow.trailingSyncPending
    debounceWindow.trailingSyncPending = false
    if needsTrailingSync {
      await syncNow()
    }
  }

  private func syncNow() async {
    if stopped { return }

    let revision = await MainActor.run { params.getStateRevision?() }

    if stopped { return }

    while inFlight {
      await withCheckedContinuation { idleWaiters.append($0) }
      if stopped { return }
    }

    // A heartbeat may already include this transition before releasing us.
    if let revision, let lastAttemptedRevision, revision <= lastAttemptedRevision { return }
    inFlight = true
    defer { finishCheckIn() }
    await performCheckIn()
  }

  private func releaseIdleWaiters() {
    let waiting = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiting { waiter.resume() }
  }

  private func finishCheckIn() {
    inFlight = false
    releaseIdleWaiters()
  }

  private func performCheckIn() async {
    // Snapshotting before the request goes out, and clearing exactly this
    // snapshot on ACK, is what keeps a fact recorded mid-flight from being
    // wiped alongside facts that were actually sent.
    let bufferedFacts = await params.getBufferedFacts()
    let (state, revision) = await MainActor.run {
      (params.getUpdateState(), params.getStateRevision?())
    }
    if let revision { lastAttemptedRevision = max(lastAttemptedRevision ?? 0, revision) }

    let response = await sendCheckIn(
      CheckInParams(
        connection: params.connection,
        sdkVersion: params.sdkVersion, channel: params.channel, attributes: params.attributes,
        lifecycleState: state,
        bufferedFacts: bufferedFacts,
        checkInIntervalMs: Int((clampedIntervalSeconds * 1000).rounded()),
        log: params.log, session: params.session))

    if response != nil { await params.clearBufferedFacts(bufferedFacts) }
    await params.onEligibilityResponse(response)
  }
}
