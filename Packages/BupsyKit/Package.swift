// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BupsyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BupsyKit", targets: ["BupsyKit"]),
        .executable(name: "spike-stream", targets: ["spike-stream"]),
    ],
    dependencies: [
        // SQLite with explicit migrations. Chosen over SwiftData because the event log is
        // append-only, reconciliation from a machine needs real queries, and migrations that
        // can be read are worth more than migrations that are inferred. docs/03-decisions.md #11.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BupsyKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
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
