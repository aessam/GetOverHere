// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "GatewaySecurityReview", platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../../Packages/TourSessionCore")],
    targets: [.testTarget(name: "GatewaySecurityReviewTests",
        dependencies: [.product(name: "TourSessionCore", package: "TourSessionCore")], path: "swift")])
