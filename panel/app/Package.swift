// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoicePanel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VoicePanel", path: "Sources/VoicePanel")
    ]
)
