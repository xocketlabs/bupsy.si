// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BupsyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BupsyKit", targets: ["BupsyKit"]),
        .executable(name: "spike-stream", targets: ["spike-stream"]),
    ],
    targets: [
        .target(
            name: "BupsyKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "spike-stream",
            dependencies: ["BupsyKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BupsyKitTests",
            dependencies: ["BupsyKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
