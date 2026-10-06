// swift-tools-version: 6.0
// SwiftPM is only here to run `swift test` on the pure parts (WaveDetector, Spring)
// on macOS; the app itself is the xcodegen project (project.yml).
import PackageDescription

let package = Package(
    name: "VisionCastCore",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "VisionCastCore", path: "Sources", sources: ["WaveDetector.swift", "Spring.swift"]),
        .testTarget(name: "VisionCastCoreTests", dependencies: ["VisionCastCore"], path: "Tests"),
    ]
)
