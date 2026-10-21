// swift-tools-version: 6.0

import PackageDescription

// The README's frames, rendered offscreen by the engine's still capture
// (ImmersiveMapStillRecorder): a package of its own, built and run from
// here, never part of the engine's build. Run through render.sh, which
// builds with xcodebuild so the engine's Metal shaders compile:
//
//   Tools/ReadmeFrames/render.sh
//
// See Sources/readme-frames/ReadmeFrames.swift for the frame list and the
// options.
let package = Package(
    name: "ReadmeFrames",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "readme-frames",
            dependencies: [
                .product(name: "ImmersiveMap", package: "ImmersiveMap")
            ]
        )
    ]
)
