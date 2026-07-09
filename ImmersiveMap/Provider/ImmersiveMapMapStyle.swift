// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

public protocol ImmersiveMapMapStyle {
    var configurationFingerprint: UInt64 { get }
    var vectorTileStyle: any ImmersiveMapVectorTileStyle { get }
}

protocol ImmersiveMapMapStyleRuntime {
    func makeRuntimeMapStyle(providerID: String,
                             settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle
}

public struct AnyImmersiveMapMapStyle: Equatable {
    public let configurationFingerprint: UInt64

    let vectorTileStyle: any ImmersiveMapVectorTileStyle
    private let runtimeMapStyleFactory: (String, ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle

    public init<S: ImmersiveMapMapStyle>(_ mapStyle: S) {
        self.configurationFingerprint = mapStyle.configurationFingerprint
        self.vectorTileStyle = mapStyle.vectorTileStyle

        if let runtimeStyle = mapStyle as? ImmersiveMapMapStyleRuntime {
            self.runtimeMapStyleFactory = runtimeStyle.makeRuntimeMapStyle
        } else {
            self.runtimeMapStyleFactory = { providerID, settings in
                GenericVectorTileStyle(providerID: providerID,
                                       style: mapStyle.vectorTileStyle,
                                       settings: settings)
            }
        }
    }

    public static func == (lhs: AnyImmersiveMapMapStyle, rhs: AnyImmersiveMapMapStyle) -> Bool {
        lhs.configurationFingerprint == rhs.configurationFingerprint
    }

    func makeRuntimeMapStyle(providerID: String,
                             settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        runtimeMapStyleFactory(providerID, settings)
    }
}

public struct VectorTileMapStyle: ImmersiveMapMapStyle {
    public let configurationFingerprint: UInt64
    public let vectorTileStyle: any ImmersiveMapVectorTileStyle

    public init(style: any ImmersiveMapVectorTileStyle,
                configurationFingerprint: UInt64? = nil) {
        self.vectorTileStyle = style
        self.configurationFingerprint = configurationFingerprint ?? UInt64(style.cacheFingerprint)
    }
}
