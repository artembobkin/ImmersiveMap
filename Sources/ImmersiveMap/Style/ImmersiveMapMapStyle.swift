// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A map style as an app configures it: the reading of the tile schema
/// (what every feature is), the vector tile style (how every feature
/// draws), and a fingerprint of the whole configuration that the disk
/// caches are keyed by.
public protocol ImmersiveMapMapStyle: Sendable {
    var configurationFingerprint: UInt64 { get }
    var schema: any ImmersiveMapTileSchema { get }
    var vectorTileStyle: any ImmersiveMapVectorTileStyle { get }
}

public struct AnyImmersiveMapMapStyle: Equatable, Sendable {
    /// The label identity namespace of a style that declares none of its
    /// own (`ImmersiveMapVectorTileStyle.styleID`).
    public static let genericStyleID = "vector"

    public let configurationFingerprint: UInt64

    let schema: any ImmersiveMapTileSchema
    let vectorTileStyle: any ImmersiveMapVectorTileStyle

    public init<S: ImmersiveMapMapStyle>(_ mapStyle: S) {
        self.configurationFingerprint = mapStyle.configurationFingerprint
        self.schema = mapStyle.schema
        self.vectorTileStyle = mapStyle.vectorTileStyle
    }

    public static func == (lhs: AnyImmersiveMapMapStyle, rhs: AnyImmersiveMapMapStyle) -> Bool {
        lhs.configurationFingerprint == rhs.configurationFingerprint
    }
}

/// Draws any MVT source with a hand-written per-feature style, over the
/// reading of its schema. The default reading is the Protomaps basemap's,
/// which covers a source that spells its tags the same way; a source that
/// names things differently pairs the style with a reading of its own.
public struct VectorTileMapStyle: ImmersiveMapMapStyle {
    public let configurationFingerprint: UInt64
    public let schema: any ImmersiveMapTileSchema
    public let vectorTileStyle: any ImmersiveMapVectorTileStyle

    public init(style: any ImmersiveMapVectorTileStyle,
                schema: any ImmersiveMapTileSchema = ProtomapsBasemapSchema(),
                configurationFingerprint: UInt64? = nil) {
        self.schema = schema
        self.vectorTileStyle = style
        self.configurationFingerprint = configurationFingerprint
            ?? (UInt64(schema.cacheFingerprint) << 32 | UInt64(style.cacheFingerprint))
    }
}
