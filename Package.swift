// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LyricsOverlay",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "LyricsOverlay",
            path: "Sources/LyricsOverlay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
