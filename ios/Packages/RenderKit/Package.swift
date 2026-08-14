// swift-tools-version: 6.0
import Foundation
import PackageDescription

// On a Command Line Tools-only Mac (no Xcode.app), `swift test` can't find
// swift-testing's `Testing.framework` without an explicit -F search path --
// Xcode wires that up itself, CLT doesn't. Gate on Xcode.app's absence (not
// just the CLT frameworks dir's presence) -- both can be on disk at once
// once a full Xcode is installed, and pulling in the CLT copy then mismatches
// Xcode's newer swift-testing macro plugin (macro-expansion "incorrect
// argument label" build errors). (Same fix as PlanKit/DetectKit Package.swift.)
let clangTestingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let needsCLTTestingWorkaround =
    !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
    && FileManager.default.fileExists(atPath: clangTestingFrameworks)
let testUnsafeFlags: [String] =
    needsCLTTestingWorkaround
    ? ["-F", clangTestingFrameworks, "-Xfrontend", "-disable-cross-import-overlays"]
    : []
// The test binary also needs this dir on its runtime search path -- -F alone
// only satisfies the compiler, dyld still looks the framework up via @rpath.
let testLinkerFlags: [String] =
    needsCLTTestingWorkaround
    ? ["-F", clangTestingFrameworks, "-Xlinker", "-rpath", "-Xlinker", clangTestingFrameworks]
    : []

let package = Package(
    name: "RenderKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RenderKit", targets: ["RenderKit"]),
    ],
    dependencies: [
        .package(path: "../PlanKit"),
    ],
    targets: [
        .target(name: "RenderKit", dependencies: ["PlanKit"]),
        .testTarget(
            name: "RenderKitTests",
            dependencies: ["RenderKit", "PlanKit"],
            swiftSettings: [.unsafeFlags(testUnsafeFlags)],
            linkerSettings: [.unsafeFlags(testLinkerFlags)]
        ),
    ]
)
