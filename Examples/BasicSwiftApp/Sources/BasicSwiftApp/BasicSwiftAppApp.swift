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
  private var subscription: Updates.Subscription?
  private var previousState: Updates.State?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // stdout is fully-buffered, not line-buffered, when piped to a test
    // harness rather than a real terminal -- short `print()` bursts would
    // otherwise sit in libc's buffer and be lost on a SIGKILL.
    setvbuf(stdout, nil, _IONBF, 0)

    let environment = ProcessInfo.processInfo.environment
    do {
      try BarrelKit.shared.initialize(
        InitConfig(
          credential: environment["BARREL_CREDENTIAL"] ?? "example-placeholder-credential",
          baseURL: environment["BARREL_BASE_URL"],
          debug: true,
          updates: Updates.Config(
            updateFeedURL: environment["BARREL_UPDATE_FEED_URL"]
          )
        )
      )
      subscription = BarrelKit.shared.updates.subscribe { [weak self] status in
        guard let self, status.state != previousState else { return }
        let state = status.state
        previousState = state
        let json =
          (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        print("[barrel-kit] lifecycleState: \(json)")
      }
    } catch {
      print("[BasicSwiftApp] BarrelKit.initialize failed: \(error)")
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    BarrelKit.shared.updates.applicationShouldTerminate() ? .terminateNow : .terminateLater
  }
}
