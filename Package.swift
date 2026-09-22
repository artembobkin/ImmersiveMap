// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ImmersiveMap",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "ImmersiveMap",
            targets: ["ImmersiveMap"]
        )
    ],
    targets: [
        // The ear-clipping triangulator, a port of mapbox/earcut. Its own
        // module so the algorithm depends on nothing in the engine and the
        // engine reaches it through one entry point at `package` access,
        // so nothing of it leaks to an app that links the product.
        .target(
            name: "Earcut"
        ),
        // The Mapbox Vector Tile decoder: the wire format, the decoded model
        // and the tile-space geometry it produces. Its own module for the same
        // reason, everything at `package` access. `TestSupport` is the
        // test-side encoder and fixture tiles both test targets share; it is
        // a regular target because test targets cannot share sources.
        .target(
            name: "Mvt"
        ),
        .target(
            name: "MvtTestSupport",
            dependencies: ["Mvt"]
        ),
        .target(
            name: "ImmersiveMap",
            dependencies: ["Earcut", "Mvt"],
            resources: [
                .process("Avatars/Resources/avatar_marker_sdf.json"),
                .process("Avatars/Resources/avatar_marker_sdf.png"),
                .process("Avatars/Shaders"),
                .process("Globe/Shaders"),
                .process("Horizon/Shaders"),
                .process("Labels/Compute/Shaders"),
                .process("Labels/Shaders"),
                .process("Render/Debug/Shaders"),
                .process("Render/PostProcessing/Shaders"),
                .process("Render/Shaders/Shared/GeoMath.metal"),
                .process("SceneModels/Shaders"),
                .process("Shadows/Shaders"),
                .process("Starfield/Shaders"),
                .process("Text/Resources"),
                .process("Text/Shaders"),
                .process("Tile/Shaders"),
            ]
        ),
        .testTarget(
            name: "EarcutTests",
            dependencies: ["Earcut"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MvtTests",
            dependencies: ["Mvt", "MvtTestSupport"]
        ),
        .testTarget(
            name: "ImmersiveMapTests",
            dependencies: ["ImmersiveMap", "Mvt", "MvtTestSupport"]
        )
    ],
    swiftLanguageModes: [.v6]
)
