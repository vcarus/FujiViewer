// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FujiViewer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "FujiViewer",
            path: "Sources/FujiViewer",
            swiftSettings: [
                // CGImage is immutable and thread safe but not Sendable; language mode v5
                // keeps the pipeline free of strict-concurrency friction.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
