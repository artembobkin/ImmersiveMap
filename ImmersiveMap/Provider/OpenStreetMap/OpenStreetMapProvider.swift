// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public struct OpenStreetMapTileProvider: ImmersiveMapTileProvider {
    public static let shortbreadV1TileBaseURL = URL(string: "https://vector.openstreetmap.org/shortbread_v1")!
    public static let shortbreadV1MaximumTileZoomLevel = 14

    public let tileBaseURL: URL

    public var id: String {
        "openstreetmap"
    }

    public var cacheNamespace: String {
        "openstreetmap-shortbread-v1"
    }

    public var configurationFingerprint: UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine(id)
        hasher.combine(cacheNamespace)
        hasher.combine(tileBaseURL.absoluteString)
        hasher.combine(String(Self.shortbreadV1MaximumTileZoomLevel))
        return hasher.finalize()
    }

    public var tileSource: ImmersiveMapTileSource {
        ImmersiveMapTileSource(tileBaseURL: tileBaseURL)
    }

    public var maximumTileZoomLevel: Int? {
        Self.shortbreadV1MaximumTileZoomLevel
    }

    public init(tileBaseURL: URL = OpenStreetMapTileProvider.shortbreadV1TileBaseURL) {
        self.tileBaseURL = tileBaseURL
    }
}

extension OpenStreetMapTileProvider: ImmersiveMapTileProviderRuntime {
    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        OpenStreetMapVectorTileLabelProviderProfile(settings: settings)
    }
}

public struct OpenStreetMapMapStyle: ImmersiveMapMapStyle {
    private let styleMode: StyleMode

    public var configurationFingerprint: UInt64 {
        UInt64(styleMode.cacheFingerprint)
    }

    public var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        styleMode.vectorTileStyle
    }

    public init(configuration: OpenStreetMapDefaultMapStyleConfiguration = .osmDefault) {
        self.styleMode = .shortbreadDefault(configuration)
    }

    public init(customStyle: any ImmersiveMapVectorTileStyle) {
        self.styleMode = .custom(customStyle)
    }
}

extension OpenStreetMapMapStyle: ImmersiveMapMapStyleRuntime {
    func makeRuntimeMapStyle(providerID: String,
                             settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        switch styleMode {
        case .shortbreadDefault(let configuration):
            return OpenStreetMapDefaultMapStyle(configuration: configuration, settings: settings)
        case .custom(let style):
            return GenericVectorTileStyle(providerID: providerID, style: style, settings: settings)
        }
    }
}

private enum StyleMode {
    case shortbreadDefault(OpenStreetMapDefaultMapStyleConfiguration)
    case custom(any ImmersiveMapVectorTileStyle)

    var cacheFingerprint: UInt32 {
        switch self {
        case .shortbreadDefault(let configuration):
            return configuration.cacheFingerprint
        case .custom(let style):
            return style.cacheFingerprint
        }
    }

    var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        switch self {
        case .shortbreadDefault(let configuration):
            return OpenStreetMapProviderVectorTileStyle(configuration: configuration)
        case .custom(let style):
            return style
        }
    }
}

private struct OpenStreetMapProviderVectorTileStyle: ImmersiveMapVectorTileStyle {
    let configuration: OpenStreetMapDefaultMapStyleConfiguration

    var cacheFingerprint: UInt32 {
        configuration.cacheFingerprint
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        .hidden
    }
}
