// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public protocol ImmersiveMapTileProvider: Sendable {
    var id: String { get }
    var cacheNamespace: String { get }
    var configurationFingerprint: UInt64 { get }
    var tileSource: ImmersiveMapTileSource { get }
    var maximumTileZoomLevel: Int? { get }

    /// Attribution of the data source behind these tiles. Shown as the map badge
    /// until the app overrides it via `attributionSettings`.
    var attribution: ImmersiveMapAttribution { get }
}

public extension ImmersiveMapTileProvider {
    /// A provider that declares no attribution gets none from the engine: an empty
    /// badge is more honest than someone else's data under the renderer's brand.
    /// If the source requires attribution (OSM and most open data do), the
    /// provider's author is responsible for setting it.
    var attribution: ImmersiveMapAttribution { .none }
}

protocol ImmersiveMapTileProviderRuntime: Sendable {
    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile
}

public struct AnyImmersiveMapTileProvider: Equatable, Sendable {
    public let id: String
    public let cacheNamespace: String
    public let configurationFingerprint: UInt64
    public let tileSource: ImmersiveMapTileSource
    public let maximumTileZoomLevel: Int?
    public let attribution: ImmersiveMapAttribution

    private let labelProviderProfileFactory: @Sendable (ImmersiveMapSettings) -> any VectorTileLabelProviderProfile

    public init<P: ImmersiveMapTileProvider>(_ provider: P) {
        self.id = provider.id
        self.cacheNamespace = provider.cacheNamespace
        self.configurationFingerprint = provider.configurationFingerprint
        self.tileSource = provider.tileSource
        self.maximumTileZoomLevel = provider.maximumTileZoomLevel
        self.attribution = provider.attribution

        if let runtimeProvider = provider as? ImmersiveMapTileProviderRuntime {
            self.labelProviderProfileFactory = runtimeProvider.makeLabelProviderProfile
        } else {
            self.labelProviderProfileFactory = { settings in
                GenericVectorTileLabelProviderProfile(providerID: provider.id,
                                                      settings: settings,
                                                      profile: .generic)
            }
        }
    }

    public static func == (lhs: AnyImmersiveMapTileProvider, rhs: AnyImmersiveMapTileProvider) -> Bool {
        lhs.id == rhs.id
            && lhs.cacheNamespace == rhs.cacheNamespace
            && lhs.configurationFingerprint == rhs.configurationFingerprint
            && lhs.tileSource == rhs.tileSource
            && lhs.maximumTileZoomLevel == rhs.maximumTileZoomLevel
            && lhs.attribution == rhs.attribution
    }

    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        labelProviderProfileFactory(settings)
    }
}

public struct VectorTileProvider: ImmersiveMapTileProvider {
    public let id: String
    public let cacheNamespace: String
    public let configurationFingerprint: UInt64
    public let tileSource: ImmersiveMapTileSource
    public let labelProfile: ImmersiveMapVectorTileLabelProfile
    public let maximumTileZoomLevel: Int?
    public let attribution: ImmersiveMapAttribution

    /// - Parameter attribution: attribution of the tile source. For OpenStreetMap
    ///   data and other open data it is required by license; the ready-made value
    ///   for pure OSM is `.openStreetMap`.
    public init(id: String,
                cacheNamespace: String? = nil,
                tileSource: ImmersiveMapTileSource,
                labelProfile: ImmersiveMapVectorTileLabelProfile = .generic,
                maximumTileZoomLevel: Int? = nil,
                attribution: ImmersiveMapAttribution = .none,
                configurationFingerprint: UInt64? = nil) {
        self.id = id
        self.cacheNamespace = cacheNamespace ?? id
        self.tileSource = tileSource
        self.labelProfile = labelProfile
        self.maximumTileZoomLevel = maximumTileZoomLevel
        self.attribution = attribution
        self.configurationFingerprint = configurationFingerprint
            ?? Self.makeFingerprint(id: id,
                                    cacheNamespace: cacheNamespace ?? id,
                                    tileSource: tileSource,
                                    labelProfileFingerprint: labelProfile.cacheFingerprint,
                                    maximumTileZoomLevel: maximumTileZoomLevel)
    }

    private static func makeFingerprint(id: String,
                                        cacheNamespace: String,
                                        tileSource: ImmersiveMapTileSource,
                                        labelProfileFingerprint: UInt64,
                                        maximumTileZoomLevel: Int?) -> UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine(id)
        hasher.combine(cacheNamespace)
        hasher.combine(tileSource.tileBaseURL.absoluteString)
        hasher.combine(String(labelProfileFingerprint))
        if let maximumTileZoomLevel {
            hasher.combine(String(maximumTileZoomLevel))
        }
        return hasher.finalize()
    }
}

extension VectorTileProvider: ImmersiveMapTileProviderRuntime {
    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        GenericVectorTileLabelProviderProfile(providerID: id,
                                              settings: settings,
                                              profile: labelProfile)
    }
}
