import BarrelKit
import SwiftUI

@main
struct BasicSwiftAppApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .windowResizability(.contentSize)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // stdout is fully-buffered, not line-buffered, when piped to a test
    // harness rather than a real terminal -- short `print()` bursts would
    // otherwise sit in libc's buffer and be lost on a SIGKILL.
    setvbuf(stdout, nil, _IONBF, 0)

    let environment = ProcessInfo.processInfo.environment
    do {
      try BarrelKit.shared.initialize(
        InitConfig(
          // A placeholder credential -- this example has no real Barrel
          // project behind it, so every check-in is expected to fail. That
          // failure is itself what the status panel below demonstrates.
          credential: environment["BARREL_CREDENTIAL"] ?? "example-placeholder-credential",
          baseURL: environment["BARREL_BASE_URL"],
          // Stops at `.available` rather than also downloading: this
          // unsigned dev build has no real update artifact to install.
          autoDownload: environment["BARREL_UPDATE_FEED_URL"] == nil,
          debug: true,
          updateFeedURL: environment["BARREL_UPDATE_FEED_URL"]
        ))
      // No UI-automation driver or IPC bridge exists for a native Swift
      // app -- a structured, single-line stdout marker is the one channel
      // a spawned test process can always observe.
      BarrelKit.shared.onStateChange { state in
        let json = (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        print("[barrel-kit] adapterState: \(json)")
        // Exercises the manual trigger the way a real `autoDownload: false`
        // host would, since this example always sets it false once a feed
        // URL is configured (see above).
        if case .available = state {
          BarrelKit.shared.downloadUpdate()
        }
      }
    } catch {
      print("[BasicSwiftApp] BarrelKit.initialize failed: \(error)")
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    BarrelKit.shared.applicationShouldTerminate() ? .terminateNow : .terminateLater
  }
}
