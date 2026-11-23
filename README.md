# Barrel for Swift

Release reporting and update eligibility for macOS applications using Sparkle. Requires macOS 13 or later and Swift 6.

## Install

There is no tagged release yet. Install from source:

```swift
.package(url: "https://github.com/barrelsystems/sdk-swift", branch: "master")
```

Add the `BarrelKit` product and configure Sparkle's feed and verification key in
your application's `Info.plist`.

## Quick start

```swift
import BarrelKit

try BarrelKit.shared.initialize(
  InitConfig(credential: "your-project-sdk-credential", updates: Updates.Config(autoDownload: false))
)
let subscription = BarrelKit.shared.updates.subscribe { status in /* render status */ }

// When status.state is .available:
try await BarrelKit.shared.updates.download()

// After verified download:
try await BarrelKit.shared.updates.apply()

subscription.remove()
```

## Example data flow

The [app delegate](Examples/BasicSwiftApp/Sources/BasicSwiftApp/BasicSwiftAppApp.swift)
initializes the native utility. The [SwiftUI view](Examples/BasicSwiftApp/Sources/BasicSwiftApp/ContentView.swift)
subscribes to `BarrelKit.shared.updates`, displays each status snapshot, and calls
that same utility from the “Restart to update” button. Automatic download remains
in the native SDK. Swift needs no IPC bridge;
the main-actor utility owns the lifecycle and validates every requested action.

## Configuration

| Setting | Default | Purpose |
| --- | --- | --- |
| `credential` | Required | Project SDK credential. |
| `baseURL` | Barrel endpoint | Reporting endpoint override for development. |
| `debug` | `false` | Diagnostic logging. |
| `updates` | Defaults below | Update-specific configuration. |

Fields inside `updates`:

| Setting | Default | Purpose |
| --- | --- | --- |
| `checkInInterval` | 30 minutes | Nominal cadence in seconds, clamped to 15 minutes–2 hours. |
| `channel` | `"stable"` | Observed release track. |
| `attributes` | Empty | String attributes included in reporting. |
| `autoDownload` | `true` | Download available updates automatically. |
| `updateFeedURL` | `SUFeedURL` | Override the appcast. |
| `holdCacheMaxAge` | 24 hours | Cached Hold lifetime in seconds; maximum seven days. |

## Update controls

Status contains `state`, `eligibility`, and `lastError`. Subscriptions receive a
complete initial snapshot and subsequent snapshots; intermediate transitions may
coalesce. Keep the returned subscription alive and remove it when no longer used.

Manual download completes after verified download. Manual apply completes at
installer handoff if the process survives long enough to return; it cannot confirm
a successful relaunch. Commands report classified errors for an unready SDK,
invalid state, a concurrent action, Hold, cancellation, or native failure.
Background reporting remains fail open.

Initialize and call update controls on the main actor. Manual commands throw
`Updates.ActionError`. Forward the application delegate's termination decision:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  BarrelKit.shared.updates.applicationShouldTerminate() ? .terminateNow : .terminateLater
}
```

## Behavior

- Reporting, verification failures, and unavailable storage fail open. A previously
  verified Hold remains effective within its configured cache lifetime.
- Downloads run automatically by default. A fresh verified Hold can defer a
  download or installation; it never prevents an ordinary application quit.
- Your application owns its release feed and artifacts. The native updater
  verifies artifacts and installs them; Barrel verifies eligibility decisions.
- Reports version, operating system, architecture, update state/errors, channel,
  configured attributes, and a locally generated installation identifier.
- `channel` is an observed, case-sensitive release track; it does not select a feed.
  Attributes are limited to 20 keys and 256 UTF-8 bytes per value.
- Debug logging is disabled by default. Reporting is best effort.

## Examples and support

- [Swift example](Examples/BasicSwiftApp)
- [Report a problem](https://github.com/barrelsystems/sdk-swift/issues)
