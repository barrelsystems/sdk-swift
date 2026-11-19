import BarrelKit
import Combine
import SwiftUI

// Hand-copied color values rather than imported from a shared package --
// this is a standalone example with no design-system dependency of its own.
extension Color {
  static let barrelCanvas = Color(red: 0x08 / 255, green: 0x0d / 255, blue: 0x0c / 255)
  static let barrelPanel = Color(red: 0x0c / 255, green: 0x11 / 255, blue: 0x11 / 255)
  static let barrelBorder = Color(red: 0x28 / 255, green: 0x2d / 255, blue: 0x2c / 255)
  static let barrelText = Color(red: 0xf4 / 255, green: 0xf5 / 255, blue: 0xf4 / 255)
  static let barrelSubtitle = Color(red: 0xb1 / 255, green: 0xb5 / 255, blue: 0xb4 / 255)
  static let barrelButton = Color(red: 0xfb / 255, green: 0xf5 / 255, blue: 0xe9 / 255)
}

/// The 4-bar logomark, traced from the Electron examples' own `<svg
/// class="logomark" viewBox="0 0 16 16">` rects at matching coordinates.
struct BarrelLogomark: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = rect.width / 16
    var path = Path()
    for bar in [(y: 1.0, h: 2.0), (y: 4.0, h: 3.0), (y: 8.0, h: 3.0), (y: 12.0, h: 3.0)] {
      path.addRect(CGRect(x: 4 * scale, y: bar.y * scale, width: 8 * scale, height: bar.h * scale))
    }
    return path
  }
}

struct ContentView: View {
  @State private var policy: Policy?
  @State private var lastError: UpdateFailure?

  private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 24) {
      BarrelLogomark()
        .fill(Color.barrelText)
        .frame(width: 40, height: 40)

      VStack(spacing: 4) {
        Text("Barrel SDK Example")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(Color.barrelText)
        Text("Packaged with Swift Package Manager")
          .font(.system(size: 14))
          .foregroundStyle(Color.barrelSubtitle)
      }

      VStack(spacing: 12) {
        statusSection(title: "Policy", value: policyDescription)
        statusSection(title: "Last update error", value: errorDescription)
      }

      Button("Apply update") {
        BarrelKit.shared.applyUpdate()
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
      .background(Color.barrelButton)
      .foregroundStyle(Color.barrelCanvas)
      .font(.system(size: 14, weight: .medium))
      .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .padding(32)
    .frame(width: 420)
    .background(Color.barrelCanvas)
    .onReceive(refreshTimer) { _ in
      policy = BarrelKit.shared.getPolicy()
      lastError = BarrelKit.shared.getLastUpdateError()
    }
  }

  private var policyDescription: String {
    guard let policy else { return "Waiting for first check-in…" }
    switch policy {
    case .current(let issuedAt, let environment): return "current (\(environment), issued \(issuedAt))"
    case .held(_, _, let reason, _): return "held\(reason.map { ": \($0)" } ?? "")"
    case .updateEligible: return "update eligible"
    }
  }

  private var errorDescription: String {
    guard let lastError else { return "None this session" }
    return "\(lastError.title) (\(lastError.platformCode))"
  }

  @ViewBuilder
  private func statusSection(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.barrelSubtitle)
      Text(value)
        .font(.system(size: 14))
        .foregroundStyle(Color.barrelText)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.barrelPanel)
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.barrelBorder, lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}
