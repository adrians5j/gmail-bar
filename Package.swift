// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GmailBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../vibe-bridge")
    ],
    targets: [
        .executableTarget(
            name: "GmailBar",
            dependencies: [.product(name: "VibeBridgeKit", package: "vibe-bridge")],
            path: "Sources/GmailBar"
        )
    ]
)
