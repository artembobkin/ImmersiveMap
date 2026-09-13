// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A map style as an app configures it: the vector tile style that says how
/// every feature draws, and a fingerprint of the whole configuration that
/// the disk caches are keyed by.
public protocol ImmersiveMapMapStyle: Sendable {
    var configurationFingerprint: UInt64 { get }
    var vectorTileStyle: any ImmersiveMapVectorTileStyle { get }
}

/// The label side of a map style: the profile that says which MVT
/// properties carry label text, rank and kind, and how labels are
/// identified. A map style that declares none gets the generic profile.
protocol ImmersiveMapMapStyleRuntime: Sendable {
    func makeLabelProfile(settings: ImmersiveMapSettings) -> any LabelStyleProfile
}

public struct AnyImmersiveMapMapStyle: Equatable, Sendable {
    /// Namespace for label identity and style hashing when a style declares
    /// none of its own.
    static let genericStyleID = "vector"

    public let configurationFingerprint: UInt64

    let vectorTileStyle: any ImmersiveMapVectorTileStyle
    private let labelProfileFactory: @Sendable (ImmersiveMapSettings) -> any LabelStyleProfile

    public init<S: ImmersiveMapMapStyle>(_ mapStyle: S) {
        self.configurationFingerprint = mapStyle.configurationFingerprint
        self.vectorTileStyle = mapStyle.vectorTileStyle

        if let runtimeStyle = mapStyle as? ImmersiveMapMapStyleRuntime {
            self.labelProfileFactory = runtimeStyle.makeLabelProfile
        } else {
            self.labelProfileFactory = { settings in
                GenericLabelStyleProfile(styleID: Self.genericStyleID,
                                         settings: settings,
                                         profile: .generic)
            }
        }
    }

    public static func == (lhs: AnyImmersiveMapMapStyle, rhs: AnyImmersiveMapMapStyle) -> Bool {
        lhs.configurationFingerprint == rhs.configurationFingerprint
    }

    func makeLabelProfile(settings: ImmersiveMapSettings) -> any LabelStyleProfile {
        labelProfileFactory(settings)
    }
}

/// Draws any MVT source with a hand-written per-feature style. The label
/// profile names which MVT properties carry label text, rank and kind, since
/// every tile schema names them differently; `.generic` reads the usual
/// OpenStreetMap-derived keys.
public struct VectorTileMapStyle: ImmersiveMapMapStyle {
    public let configurationFingerprint: UInt64
    public let vectorTileStyle: any ImmersiveMapVectorTileStyle
    public let labelProfile: ImmersiveMapVectorTileLabelProfile

    public init(style: any ImmersiveMapVectorTileStyle,
                labelProfile: ImmersiveMapVectorTileLabelProfile = .generic,
                configurationFingerprint: UInt64? = nil) {
        self.vectorTileStyle = style
        self.labelProfile = labelProfile
        self.configurationFingerprint = configurationFingerprint
            ?? Self.makeFingerprint(styleFingerprint: style.cacheFingerprint,
                                    labelProfileFingerprint: labelProfile.cacheFingerprint)
    }

    private static func makeFingerprint(styleFingerprint: UInt32,
                                        labelProfileFingerprint: UInt64) -> UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine(String(styleFingerprint))
        hasher.combine(String(labelProfileFingerprint))
        return hasher.finalize()
    }
}

extension VectorTileMapStyle: ImmersiveMapMapStyleRuntime {
    func makeLabelProfile(settings: ImmersiveMapSettings) -> any LabelStyleProfile {
        GenericLabelStyleProfile(styleID: AnyImmersiveMapMapStyle.genericStyleID,
                                 settings: settings,
                                 profile: labelProfile)
    }
}
