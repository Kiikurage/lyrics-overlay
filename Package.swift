// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LyricsOverlay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LyricsOverlay",
            path: "Sources/LyricsOverlay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
