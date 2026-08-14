// swift-tools-version: 6.0
import Foundation
import PackageDescription

// On a Command Line Tools-only Mac (no Xcode.app), `swift test` can't find
// swift-testing's `Testing.framework` without an explicit -F search path —
// Xcode wires that up itself, CLT doesn't. Gate on Xcode.app's ABSENCE, not
// on the CLT Frameworks path's existence: CLT stays installed even after
// Xcode is added, so checking only "does the CLT path exist" force-enables
// this under a full Xcode install too and pulls in CLT's older swift-testing
// macro ABI, which conflicts with Xcode's and fails the build with
// "incorrect argument label '__uncheckedFileID:'".
let xcodeInstalled = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
let clangTestingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testUnsafeFlags: [String] =
    !xcodeInstalled && FileManager.default.fileExists(atPath: clangTestingFrameworks)
    ? ["-F", clangTestingFrameworks]
    : []

// `-F` alone locates Testing.framework to link against at build time; the
// test binary still needs the same directory in its runtime search path
// (rpath) to dlopen it when `swift test` launches the bundle, since it
// lives outside the standard dyld locations on a CLT-only install.
let testLinkerUnsafeFlags: [String] =
    !xcodeInstalled && FileManager.default.fileExists(atPath: clangTestingFrameworks)
    ? ["-F", clangTestingFrameworks, "-Xlinker", "-rpath", "-Xlinker", clangTestingFrameworks]
    : []

// This CLT install ships a `_Testing_Foundation.framework` bundle whose
// Modules/ dir is empty (no actual .swiftmodule content) — a stub, like
// XCTest.framework was. Swift auto-loads it as a cross-import overlay the
// moment a file imports both `Testing` and `Foundation`, which fails to
// resolve. We don't use its Foundation-specific #expect conveniences, so
// disabling cross-import overlay auto-loading sidesteps the stub entirely.
let testSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(testUnsafeFlags + ["-Xfrontend", "-disable-cross-import-overlays"])
]

let package = Package(
    name: "DetectKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "DetectKit", targets: ["DetectKit"]),
    ],
    targets: [
        .target(name: "MediaKit"),
        .target(name: "DetectKit", dependencies: ["MediaKit"]),
        .testTarget(
            name: "MediaKitTests",
            dependencies: ["MediaKit"],
            swiftSettings: testSwiftSettings,
            linkerSettings: [.unsafeFlags(testLinkerUnsafeFlags)]
        ),
        .testTarget(
            name: "DetectKitTests",
            dependencies: ["DetectKit", "MediaKit"],
            swiftSettings: testSwiftSettings,
            linkerSettings: [.unsafeFlags(testLinkerUnsafeFlags)]
        ),
    ]
)
