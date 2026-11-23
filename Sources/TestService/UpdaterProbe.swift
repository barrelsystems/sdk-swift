import Foundation
import Sparkle

@testable import BarrelKit

struct UpdaterActivity: Codable, Sendable {
  var checks = 0
  var downloads = 0
  var applies = 0
}

@MainActor
final class UpdaterProbe {
  var activity = UpdaterActivity()
  weak var adapter: SparkleUpdaterAdapter?
  private var available = false

  func checkForUpdates() {
    activity.checks += 1
    if available {
      offerUpdate()
    } else {
      reportNoUpdate()
    }
  }

  func reportNoUpdate() {
    available = false
    adapter?.showUpdateNotFoundWithError(
      NSError(domain: "SUSparkleErrorDomain", code: Int(SUError.noUpdateError.rawValue)),
      acknowledgement: {})
  }

  func offerUpdate(releaseNotes: String? = nil) {
    available = true
    adapter?.handleUpdateFound(version: "2.0.0", releaseNotes: releaseNotes) { [weak self] choice in
      if choice == .install {
        self?.activity.downloads += 1
        self?.adapter?.showReady(toInstallAndRelaunch: { _ in })
      }
    }
  }

  func prepare(stage: PreActionStage) {
    offerUpdate()
    if stage == .preApply {
      adapter?.showReady(toInstallAndRelaunch: { [weak self] choice in
        if choice == .install { self?.activity.applies += 1 }
      })
    }
  }
}
