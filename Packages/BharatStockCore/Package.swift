// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BharatStockCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BharatStockCore", targets: ["BharatStockCore"])
    ],
    targets: [
        .target(
            name: "BharatStockCore",
            resources: [.process("Resources")],
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
