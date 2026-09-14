// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A map style as an app configures it: the vector tile style that says how
/// every feature draws, and a fingerprint of the whole configuration that
/// the disk caches are keyed by.
public protocol ImmersiveMapMapStyle: Sendable {
    var configurationFingerprint: UInt64 { get }
    var vectorTileStyle: any ImmersiveMapVectorTileStyle { get }
}

public struct AnyImmersiveMapMapStyle: Equatable, Sendable {
    /// The label identity namespace of a style that declares none of its
    /// own (`ImmersiveMapVectorTileStyle.styleID`).
    public static let genericStyleID = "vector"

    public let configurationFingerprint: UInt64

    let vectorTileStyle: any ImmersiveMapVectorTileStyle

    public init<S: ImmersiveMapMapStyle>(_ mapStyle: S) {
        self.configurationFingerprint = mapStyle.configurationFingerprint
        self.vectorTileStyle = mapStyle.vectorTileStyle
    }

    public static func == (lhs: AnyImmersiveMapMapStyle, rhs: AnyImmersiveMapMapStyle) -> Bool {
        lhs.configurationFingerprint == rhs.configurationFingerprint
    }
}

/// Draws any MVT source with a hand-written per-feature style. Which
/// properties carry a label's text and rank is the style's to say, since
/// every tile schema names them differently.
public struct VectorTileMapStyle: ImmersiveMapMapStyle {
    public let configurationFingerprint: UInt64
    public let vectorTileStyle: any ImmersiveMapVectorTileStyle

    public init(style: any ImmersiveMapVectorTileStyle,
                configurationFingerprint: UInt64? = nil) {
        self.vectorTileStyle = style
        self.configurationFingerprint = configurationFingerprint ?? UInt64(style.cacheFingerprint)
    }
}
