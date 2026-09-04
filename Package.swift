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
        .target(
            name: "ImmersiveMap",
            dependencies: ["Earcut"],
            path: "ImmersiveMap",
            exclude: [
                "Avatars/README.md",
                "Camera/README.md",
                "Configuration/README.md",
                "Geo/README.md",
                "Globe/README.md",
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
            name: "ImmersiveMapTests",
            dependencies: ["ImmersiveMap"],
            path: "Tests/ImmersiveMapTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
