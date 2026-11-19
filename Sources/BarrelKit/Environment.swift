import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct ObservedEnvironment {
  var observedVersion: String
  var platform: String
  var arch: String
  var osVersion: String
}

func collectEnvironment() -> ObservedEnvironment {
  let version =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  let os = ProcessInfo.processInfo.operatingSystemVersion
  #if arch(arm64)
  let arch = "arm64"
  #else
  let arch = "x64"
  #endif

  return ObservedEnvironment(
    observedVersion: version,
    platform: "darwin",
    arch: arch,
    osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
  )
}
