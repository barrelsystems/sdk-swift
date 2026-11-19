# BarrelKit

Barrel's release-intelligence SDK for Swift/Sparkle apps on macOS. It
implements Sparkle's `SPUUserDriver` headlessly, with no UI of its own, so
your app never calls Sparkle directly — and reports what actually happened
on a check, download, or install.

Your appcast and binaries stay on your own infrastructure. Barrel doesn't
host or verify either.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/barrel-kit/sdk-swift", from: "0.0.1")
```

Requires macOS 13+.

## Use it

In `applicationDidFinishLaunching(_:)`:

```swift
import BarrelKit

try? BarrelKit.shared.initialize(InitConfig(credential: ProcessInfo.processInfo.environment["BARREL_CREDENTIAL"] ?? ""))
```

Your feed URL is still configured the normal Sparkle way, via `SUFeedURL`
in your own `Info.plist`. (`InitConfig.updateFeedURL` only exists to
override that for your own test builds — don't set it in anything you
ship.)

Read state or subscribe to it anywhere else in your app:

```swift
let policy = BarrelKit.shared.getPolicy() // Policy?
let state = BarrelKit.shared.getAdapterState() // AdapterState?
let lastError = BarrelKit.shared.getLastUpdateError() // UpdateFailure?

BarrelKit.shared.onStateChange { state in /* re-render on every local transition */ }

BarrelKit.shared.downloadUpdate() // manual trigger, for autoDownload: false
BarrelKit.shared.applyUpdate() // host-triggered install, ahead of the natural quit-time default
```

macOS doesn't give a library any way to intercept app termination on its
own the way Electron's `before-quit` event does, so there's one more hook,
in `applicationShouldTerminate(_:)`:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  BarrelKit.shared.applicationShouldTerminate() ? .terminateNow : .terminateLater
}
```

`initialize()` only throws for a blank `credential`. Past that it fails
open — a bad signature or an unreachable backend never gets in the way of
a real update.

## Behavior

Checks in on launch and then every 30 minutes (15-minute floor), jittered
per install. Policy signatures are verified with Apple's own `CryptoKit`,
nothing third-party. Facts recorded offline get buffered to disk, with
repeats merged rather than duplicated and the oldest non-terminal entry
evicted first if the buffer fills. A fresh pre-action check runs
immediately before every download and apply, separately from the
30-minute cadence, so a Hold placed since the last check-in still has time
to land.

The SDK implements `SPUUserDriver` itself rather than sitting on the side
as a passive `SPUUpdaterDelegate` observer, which is what lets it see every
byte-level progress and checking signal instead of losing some of them.
`AdapterState` reports the real lifecycle
(`idle`/`checking`/`available`/`downloading`/`downloaded`/`updateCancelled`/`failed`),
with failures classified into the same `failureMode` taxonomy every Barrel
SDK shares — `getLastUpdateError()` to read it, `onStateChange()` to
subscribe. Release notes come through on `AdapterState.available` whenever
Sparkle's own appcast has any.

A few smaller things: the SDK supports server-directed rotation of the
trusted key it ships with, keeps one random installation ID on disk, and
clamps whatever custom attributes you attach so they can't balloon a
check-in past what Barrel will accept. Debug logging goes through `print`
and is off unless you ask for it with `InitConfig(debug: true)`. An
unexpected bug in this SDK's own adapter code is tallied locally by cause,
never captured or sent anywhere, so one can never crash your app.

## What stays yours

Channels, targeting, and rollout percentages live on Barrel's dashboard.
Your appcast and the binaries it points at are entirely yours, configured
the normal Sparkle way via `SUFeedURL`.

## Dependencies

One: `Sparkle` itself, the thing being wrapped. Everything else —
`CryptoKit`, `Foundation`, `AppKit` — is a system framework. This ships
inside your app, so we keep the dependency list as short as we can.
