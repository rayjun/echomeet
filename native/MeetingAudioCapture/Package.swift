// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAudioCapture",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MeetingAudioCapture",
            path: "Sources/MeetingAudioCapture"
        )
    ]
)