// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BarrelKit",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "BarrelKit", targets: ["BarrelKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
  ],
  targets: [
    .target(
      name: "BarrelKit",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ]
    ),
    .testTarget(
      name: "BarrelKitTests",
      dependencies: [
        "BarrelKit",
        .product(name: "Sparkle", package: "Sparkle"),
      ]
    ),
  ]
)
