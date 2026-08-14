// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlanKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PlanKit", targets: ["PlanKit"]),
    ],
    targets: [
        .target(name: "PlanKit"),
        .testTarget(name: "PlanKitTests", dependencies: ["PlanKit"]),
        // Framework-free mirror of the same checks, runnable without swift-testing:
        // `swift run plankit-selfcheck`. See Sources/plankit-selfcheck/main.swift.
        .executableTarget(name: "plankit-selfcheck", dependencies: ["PlanKit"]),
    ]
)
