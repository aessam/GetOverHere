// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "drift2", platforms: [.macOS(.v15)],
  dependencies: [.package(path: "/Users/aessam/tmp/ios-macos-apps/GetOverHere/Packages/TourSessionCore")],
  targets: [.executableTarget(name: "drift2", dependencies: [.product(name: "TourSessionCore", package: "TourSessionCore")])])
