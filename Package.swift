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
            name: "Earcut",
            path: "Earcut",
            exclude: ["README.md", "Tests"]
        ),
        // The Mapbox Vector Tile decoder: the wire format, the decoded model
        // and the tile-space geometry it produces. Its own module for the same
        // reason, everything at `package` access. `TestSupport` is the
        // test-side encoder and fixture tiles both test targets share; it is
        // a regular target because test targets cannot share sources.
        .target(
            name: "Mvt",
            path: "Mvt",
            exclude: ["README.md", "Tests", "TestSupport"]
        ),
        .target(
            name: "MvtTestSupport",
            dependencies: ["Mvt"],
            path: "Mvt/TestSupport"
        ),
        .target(
            name: "ImmersiveMap",
            dependencies: ["Earcut", "Mvt"],
            path: "ImmersiveMap",
            exclude: [
                "Avatars/README.md",
                "Camera/README.md",
                "Configuration/README.md",
                "Geo/README.md",
                "Globe/README.md",
                "Horizon/README.md",
                "ImmersiveMap.docc/README.md",
                "Labels/README.md",
                "Markers/README.md",
                "Presentation/README.md",
                "Render/README.md",
                "Routes/README.md",
                "SceneModels/README.md",
                "Starfield/README.md",
                "StillCapture/README.md",
                "Text/README.md",
                "Tile/README.md",
                "UI/README.md",
                "Utils/README.md",
                "VectorTileAdaptation/README.md",
                "VideoExport/README.md"
            ],
            resources: [
                .process("Render/Avatars/Resources/avatar_marker_sdf.json"),
                .process("Render/Avatars/Resources/avatar_marker_sdf.png"),
                .process("Render/Avatars/Shaders"),
                .process("Render/Labels/Compute/Shaders"),
                .process("Render/Labels/Shaders"),
                .process("Render/Text/Shaders"),
                .process("Text/Resources"),
                .process("Render/PostProcessing/Shaders"),
                .process("Render/Shaders/Globe"),
                .process("Render/Shaders/Horizon"),
                .process("Render/Shaders/Starfield"),
                .process("Render/Compute/TilePoints/Shaders/TilePointToScreen.metal"),
                .process("Render/Debug/Shaders"),
                .process("Render/Routes/Shaders"),
                .process("Render/SceneModels/Shaders"),
                .process("Render/Shaders/Shared/GeoMath.metal"),
                .process("Render/Tiles/Shaders"),
            ]
        ),
        .testTarget(
            name: "EarcutTests",
            dependencies: ["Earcut"],
            path: "Earcut/Tests"
        ),
        .testTarget(
            name: "MvtTests",
            dependencies: ["Mvt", "MvtTestSupport"],
            path: "Mvt/Tests"
        ),
        .testTarget(
            name: "ImmersiveMapTests",
            dependencies: ["ImmersiveMap", "Mvt", "MvtTestSupport"],
            path: "Tests/ImmersiveMapTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
