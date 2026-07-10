// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ImmersiveMap",
    platforms: [
        .iOS(.v18),
        .macCatalyst(.v18),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ImmersiveMap",
            targets: ["ImmersiveMap"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/measuredweighed/SwiftEarcut.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.0")
    ],
    targets: [
        .target(
            name: "ImmersiveMap",
            dependencies: [
                "SwiftEarcut",
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "ImmersiveMap",
            exclude: [
                "Avatars/README.md",
                "Camera/README.md",
                "Configuration/README.md",
                "Generated/README.md",
                "Geo/README.md",
                "Globe/README.md",
                "ImmersiveMap.docc/README.md",
                "Labels/README.md",
                "Presentation/README.md",
                "Proto/README.md",
                "Render/README.md",
                "Starfield/README.md",
                "Text/README.md",
                "Tile/README.md",
                "UI/README.md",
                "Utils/README.md",
                "VectorTileAdaptation/README.md"
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
                .process("Render/Shaders/Shared/GeoMath.metal"),
                .process("Render/Tiles/Shaders"),
                .copy("Proto/vector_tile.proto")
            ]
        ),
        .testTarget(
            name: "ImmersiveMapTests",
            dependencies: ["ImmersiveMap"],
            path: "Tests/ImmersiveMapTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
