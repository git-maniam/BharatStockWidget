// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BharatStockCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BharatStockCore", targets: ["BharatStockCore"]),
        .executable(name: "bharatstock-dryrun", targets: ["bharatstock-dryrun"]),
    ],
    targets: [
        .target(
            name: "BharatStockCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // §8's smoke test: runs a full refresh cycle against fixtures, spends no budget, and
        // prints the cache it would have written.
        .executableTarget(
            name: "bharatstock-dryrun",
            dependencies: ["BharatStockCore"],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BharatStockCoreTests",
            dependencies: ["BharatStockCore"],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
