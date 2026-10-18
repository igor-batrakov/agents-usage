// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageWidget",
    platforms: [.macOS("15.0")],
    targets: [
        .target(
            name: "UsageCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "UsageWidget",
            dependencies: ["UsageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
