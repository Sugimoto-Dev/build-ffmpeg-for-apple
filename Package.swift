// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BuildFFmpegForApple",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BuildFFmpegCore", targets: ["BuildFFmpegCore"]),
        .executable(name: "BuildFFmpegCommandBuilder", targets: ["BuildFFmpegCommandBuilder"]),
    ],
    targets: [
        .target(
            name: "BuildFFmpegCore"
        ),
        .executableTarget(
            name: "BuildFFmpegCommandBuilder",
            dependencies: ["BuildFFmpegCore"]
        ),
        .testTarget(
            name: "BuildFFmpegCoreTests",
            dependencies: ["BuildFFmpegCore"]
        ),
    ]
)
