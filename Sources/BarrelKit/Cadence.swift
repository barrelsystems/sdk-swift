import AppKit
import Foundation

let defaultIntervalSeconds: TimeInterval = 30 * 60
let minIntervalSeconds: TimeInterval = 15 * 60
let defaultHoldCacheMaxAge: TimeInterval = 24 * 60 * 60
let maxHoldCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60
let sdkVersion = "0.1.0"

struct CadenceParams: Sendable {
  var connection: BackendConnection
  var checkInInterval: TimeInterval
  var sdkVersion: String
  var channel: String
  var attributes: [String: String]
  var log: (@Sendable (String) -> Void)?
  var getAdapterState: @MainActor () -> AdapterState
  var getBufferedFacts: @Sendable () async -> [BufferedFact]
  /// Called only once ingestion ACKs the check-in that carried `sent` -- never optimistically.
  var clearBufferedFacts: @Sendable ([BufferedFact]) async -> Void
  var checkForUpdates: @MainActor () -> Void
  var onPolicyResponse: @MainActor (CheckInResponse?) async -> Void
  var getPolicy: @MainActor () -> Policy?
  var holdCacheMaxAge: TimeInterval
}

/// Only a confirmed `held` Policy still within its ceiling holds the check --
/// the ceiling is the earlier of `holdCacheMaxAge` and the operator's own
/// `until`, so a client stuck offline fails open instead of staying held forever.
func policyHoldsTheVendorCheck(_ policy: Policy?, holdCacheMaxAge: TimeInterval, now: Date = Date()) -> Bool {
  guard case .held(let issuedAt, _, _, let until) = policy else { return false }
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
      "cadence: requested interval \(params.checkInInterval)s is below the \(minIntervalSeconds)s floor, clamped")
  }
  let interval = max(params.checkInInterval, minIntervalSeconds)
  let jitterFraction = computeJitterFraction(installationId: params.connection.installationId)
  let jitteredInterval = interval * (1 + jitterFraction)

  let ticker = CadenceTicker(params: params)

  Task { await ticker.tick() }
  Timer.scheduledTimer(withTimeInterval: jitteredInterval, repeats: true) { _ in
    Task { await ticker.tick() }
  }

  NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
  ) { _ in Task { await ticker.tick() } }

  NotificationCenter.default.addObserver(
    forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
  ) { _ in Task { await ticker.tick() } }

  return ticker
}

actor CadenceTicker {
  private let params: CadenceParams
  private var inFlight = false

  init(params: CadenceParams) {
    self.params = params
  }

  // A tick that fires while the previous one is still in flight is
  // skipped, not queued -- overlapping attempts are impossible.
  func tick() async {
    if inFlight {
      params.log?("cadence: tick skipped, a check-in is already in flight")
      return
    }
    inFlight = true
    defer { inFlight = false }

    // The vendor update-feed check piggybacks on this same cadence but
    // MUST NOT run while held -- a Hold gates the check itself, not just
    // the download/apply actions downstream of it.
    let policy = await MainActor.run { params.getPolicy() }
    if !policyHoldsTheVendorCheck(policy, holdCacheMaxAge: params.holdCacheMaxAge) {
      await MainActor.run { params.checkForUpdates() }
    }

    // Snapshotting before the request goes out, and clearing exactly this
    // snapshot on ACK, is what keeps a fact recorded mid-flight from being
    // wiped alongside facts that were actually sent.
    let bufferedFacts = await params.getBufferedFacts()
    let response = await sendCheckIn(
      CheckInParams(
        connection: params.connection,
        sdkVersion: params.sdkVersion, channel: params.channel, attributes: params.attributes,
        adapterState: await MainActor.run { params.getAdapterState() },
        bufferedFacts: bufferedFacts, log: params.log))

    if response != nil { await params.clearBufferedFacts(bufferedFacts) }
    await params.onPolicyResponse(response)
  }
}
