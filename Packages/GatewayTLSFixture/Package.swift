// swift-tools-version: 6.2
import PackageDescription

// Test-only executable. This package is not linked into either application.
let package = Package(
    name: "GatewayTLSFixture",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../LocalLinkSecurity")],
    targets: [.executableTarget(name: "gateway-tls-fixture", dependencies: [
        .product(name: "LocalLinkSecurity", package: "LocalLinkSecurity"),
    ])]
)
