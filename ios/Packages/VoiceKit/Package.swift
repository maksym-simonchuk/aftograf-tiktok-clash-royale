// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VoiceKit", targets: ["VoiceKit"]),
    ],
    targets: [
        .target(name: "VoiceKit"),
        .executableTarget(name: "voicekit-smoke", dependencies: ["VoiceKit"]),
        // Offline assert()-based check, runnable via `swift run voicekit-selfcheck`.
        // `swift test` cannot execute in this sandbox (no Xcode: no `xctest` tool
        // for the default runner, unaccepted Xcode license blocks the native
        // swift-testing runner) -- it silently exits 0 having run zero tests. This
        // target is real, executed verification until that's fixed.
        .executableTarget(name: "voicekit-selfcheck", dependencies: ["VoiceKit"]),
        .testTarget(name: "VoiceKitTests", dependencies: ["VoiceKit"]),
    ]
)
