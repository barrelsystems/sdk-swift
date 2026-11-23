import BarrelKit
import SwiftUI

struct ContentView: View {
  @State private var state: Updates.State = .idle
  @State private var subscription: Updates.Subscription?
  @State private var actionError: String?
  @State private var restarting = false

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "arrow.down.circle")
        .font(.system(size: 32, weight: .light))
      Text("Software update")
        .font(.title3.weight(.semibold))
      Text(actionError ?? message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if case .downloading(let progress) = state {
        if let progress {
          ProgressView(value: Double(progress), total: 100)
        } else {
          ProgressView()
        }
      }

      if state == .downloaded {
        Button("Restart to update") {
          Task {
            restarting = true
            defer { restarting = false }
            do { try await BarrelKit.shared.updates.apply() } catch Updates.ActionError.held {
              actionError = "This update isn’t ready yet. Please try again later."
            } catch {
              actionError = "The update couldn’t be installed. Please try again."
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(restarting)
      }
    }
    .padding(40)
    .frame(width: 320)
    .onAppear {
      subscription = BarrelKit.shared.updates.subscribe { status in state = status.state }
    }
    .onDisappear {
      subscription?.remove()
      subscription = nil
    }
  }

  private var message: String {
    switch state {
    case .idle: return "Updates run in the background."
    case .checking: return "Checking for updates…"
    case .available: return "An update is available."
    case .downloading: return "Downloading update…"
    case .downloaded: return "Your update is ready."
    case .applying: return "Restarting…"
    case .updateCancelled: return "The update was cancelled."
    case .failed: return "The update couldn’t be completed. We’ll check again later."
    }
  }
}
