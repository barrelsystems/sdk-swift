// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BasicSwiftApp",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "BasicSwiftApp", targets: ["BasicSwiftApp"])
  ],
  dependencies: [
    .package(path: "../..")
  ],
  targets: [
    .executableTarget(
      name: "BasicSwiftApp",
      dependencies: [.product(name: "BarrelKit", package: "sdk-swift")],
      exclude: ["Resources/Info.plist"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/BasicSwiftApp/Resources/Info.plist",
        ])
      ]
    )
  ]
)
