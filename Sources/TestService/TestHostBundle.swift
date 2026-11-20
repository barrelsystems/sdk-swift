import Foundation

/// A plain SPM executable's `Bundle.main` has no `Info.plist` -- Sparkle
/// needs a real bundle identifier to run its update-check pipeline at all.
func makeTestHostBundle() -> Bundle {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("barrelkit-test-host-\(UUID().uuidString)")
  let contents = directory.appendingPathComponent("Contents")
  do {
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
  } catch {
    fatalError("test-service: could not create a throwaway host bundle directory: \(error)")
  }

  let info: [String: Any] = [
    "CFBundleIdentifier": "codes.barrel.test-service",
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "1",
    "CFBundleExecutable": "TestHost",
    // ATS blocks plain HTTP by default, even to localhost -- this test
    // service's own mock feed/download servers are deliberately HTTP.
    "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true],
  ]

  guard let plistData = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
  else {
    fatalError("test-service: could not serialize the throwaway host bundle's Info.plist")
  }
  do {
    try plistData.write(to: contents.appendingPathComponent("Info.plist"))
  } catch {
    fatalError("test-service: could not write the throwaway host bundle's Info.plist: \(error)")
  }

  guard let bundle = Bundle(url: directory) else {
    fatalError("test-service: Bundle(url:) returned nil for the just-written host bundle at \(directory)")
  }
  return bundle
}
