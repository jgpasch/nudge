// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nudge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "nudge", targets: ["nudge"]),
        .library(name: "NudgeCore", targets: ["NudgeCore"]),
    ],
    targets: [
        .target(name: "NudgeCore"),
        .executableTarget(name: "nudge", dependencies: ["NudgeCore"]),
    ]
)
