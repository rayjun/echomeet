// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoMeet",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "EchoMeet",
            path: "MeetingTranslatorApp",
            exclude: [
                "Info.plist",
                "MeetingTranslatorApp.entitlements"
            ],
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)