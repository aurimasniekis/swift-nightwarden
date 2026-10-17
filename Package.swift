// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nightwarden",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NightwardenCore"),
        .executableTarget(name: "Nightwarden", dependencies: ["NightwardenCore"]),
        .testTarget(name: "NightwardenCoreTests", dependencies: ["NightwardenCore"]),
    ]
)
