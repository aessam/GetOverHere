// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalLinkSecurity",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "LocalLinkSecurity", targets: ["LocalLinkSecurity"])],
    dependencies: [.package(url: "https://github.com/apple/swift-certificates.git", exact: "1.20.0")],
    targets: [
        .target(name: "LocalLinkSecurity", dependencies: [
            .product(name: "X509", package: "swift-certificates"),
        ], resources: [.process("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "LocalLinkSecurityTests", dependencies: ["LocalLinkSecurity"]),
    ]
)
