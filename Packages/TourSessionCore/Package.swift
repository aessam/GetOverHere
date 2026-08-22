// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TourSessionCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
    ],
    products: [
        .library(name: "TourSessionCore", targets: ["TourSessionCore"]),
        .executable(name: "tour-session-swift", targets: ["TourSessionCLI"]),
    ],
    targets: [
        .target(name: "TourSessionCore"),
        .executableTarget(
            name: "TourSessionCLI",
            dependencies: ["TourSessionCore"]
        ),
        .testTarget(
            name: "TourSessionCoreTests",
            dependencies: ["TourSessionCore"]
        ),
    ]
)
