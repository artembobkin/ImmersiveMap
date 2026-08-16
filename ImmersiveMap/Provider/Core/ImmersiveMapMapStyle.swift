// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

public protocol ImmersiveMapMapStyle: Sendable {
    var configurationFingerprint: UInt64 { get }
    var vectorTileStyle: any ImmersiveMapVectorTileStyle { get }
}

/// The runtime side of a map style: how to build the live style object and the
/// label profile that says which MVT properties carry label text. The tile
/// source is just a URL; everything about interpreting the bytes it serves
/// lives here.
protocol ImmersiveMapMapStyleRuntime: Sendable {
    func makeRuntimeMapStyle(settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle
    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile
}

public struct AnyImmersiveMapMapStyle: Equatable, Sendable {
    /// Namespace for label identity and style hashing when a style declares
    /// none of its own.
    static let genericStyleID = "vector"

    public let configurationFingerprint: UInt64

    let vectorTileStyle: any ImmersiveMapVectorTileStyle
    private let runtimeMapStyleFactory: @Sendable (ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle
    private let labelProviderProfileFactory: @Sendable (ImmersiveMapSettings) -> any VectorTileLabelProviderProfile

    public init<S: ImmersiveMapMapStyle>(_ mapStyle: S) {
        self.configurationFingerprint = mapStyle.configurationFingerprint
        self.vectorTileStyle = mapStyle.vectorTileStyle

        if let runtimeStyle = mapStyle as? ImmersiveMapMapStyleRuntime {
            self.runtimeMapStyleFactory = runtimeStyle.makeRuntimeMapStyle
            self.labelProviderProfileFactory = runtimeStyle.makeLabelProviderProfile
        } else {
            self.runtimeMapStyleFactory = { settings in
                GenericVectorTileStyle(providerID: Self.genericStyleID,
                                       style: mapStyle.vectorTileStyle,
                                       settings: settings)
            }
            self.labelProviderProfileFactory = { settings in
                GenericVectorTileLabelProviderProfile(providerID: Self.genericStyleID,
                                                      settings: settings,
                                                      profile: .generic)
            }
        }
    }

    public static func == (lhs: AnyImmersiveMapMapStyle, rhs: AnyImmersiveMapMapStyle) -> Bool {
        lhs.configurationFingerprint == rhs.configurationFingerprint
    }

    func makeRuntimeMapStyle(settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        runtimeMapStyleFactory(settings)
    }

    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        labelProviderProfileFactory(settings)
    }
}

/// Draws any MVT source with a hand-written per-feature style. The label
/// profile names which MVT properties carry label text, rank and kind, since
/// every tile schema names them differently; `.generic` reads the usual
/// OpenMapTiles-style keys.
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
    func makeRuntimeMapStyle(settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        GenericVectorTileStyle(providerID: AnyImmersiveMapMapStyle.genericStyleID,
                               style: vectorTileStyle,
                               settings: settings)
    }

    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        GenericVectorTileLabelProviderProfile(providerID: AnyImmersiveMapMapStyle.genericStyleID,
                                              settings: settings,
                                              profile: labelProfile)
    }
}
