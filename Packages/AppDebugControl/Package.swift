// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppDebugControl",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "AppDebugControl", targets: ["AppDebugControl"]),
        .executable(name: "goh-control", targets: ["DebugControlCLI"]),
    ],
    targets: [
        .target(name: "AppDebugControl"),
        .executableTarget(name: "DebugControlCLI", dependencies: ["AppDebugControl"]),
        .testTarget(name: "AppDebugControlTests", dependencies: ["AppDebugControl"]),
    ]
)
