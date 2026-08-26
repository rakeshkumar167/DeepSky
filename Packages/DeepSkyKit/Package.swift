// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DeepSkyKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "DeepSkyCore", targets: ["DeepSkyCore"]),
        .library(name: "DeepSkyCapture", targets: ["DeepSkyCapture"]),
        .library(name: "DeepSkyMetrics", targets: ["DeepSkyMetrics"]),
        .library(name: "DeepSkySession", targets: ["DeepSkySession"]),
        .library(name: "DeepSkySynthetic", targets: ["DeepSkySynthetic"]),
        .library(name: "DeepSkyAVCapture", targets: ["DeepSkyAVCapture"]),
    ],
    targets: [
        .target(name: "DeepSkyCore"),
        .target(name: "DeepSkyCapture", dependencies: ["DeepSkyCore"]),
        .target(name: "DeepSkyMetrics", dependencies: ["DeepSkyCore"]),
        .target(name: "DeepSkySession",
                dependencies: ["DeepSkyCore", "DeepSkyCapture", "DeepSkyMetrics"]),
        .target(name: "DeepSkySynthetic", dependencies: ["DeepSkyCore", "DeepSkyCapture"]),
        // iOS-only: the single target permitted to import AVFoundation.
        // Its contents are #if os(iOS) guarded so the macOS test build stays green.
        .target(name: "DeepSkyAVCapture",
                dependencies: ["DeepSkyCore", "DeepSkyCapture", "DeepSkySession"]),
        .testTarget(name: "DeepSkyCoreTests", dependencies: ["DeepSkyCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "DeepSkyMetricsTests", dependencies: ["DeepSkyMetrics", "DeepSkyCore"]),
        .testTarget(name: "DeepSkySessionTests",
                    dependencies: ["DeepSkySession", "DeepSkyCore", "DeepSkyCapture", "DeepSkySynthetic"]),
        .testTarget(name: "DeepSkySyntheticTests",
                    dependencies: ["DeepSkySynthetic", "DeepSkyCapture", "DeepSkyCore"]),
    ]
)
