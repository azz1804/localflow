// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LocalFlowCore", targets: ["LocalFlowCore"]),
        .executable(name: "LocalFlow", targets: ["LocalFlowApp"])
    ],
    targets: [
        .target(name: "LocalFlowCore"),
        .executableTarget(
            name: "LocalFlowApp",
            dependencies: ["LocalFlowCore"]
        ),
        .testTarget(
            name: "LocalFlowCoreTests",
            dependencies: ["LocalFlowCore"]
        ),
        .testTarget(
            name: "LocalFlowAppTests",
            dependencies: ["LocalFlowApp"]
        )
    ]
)
