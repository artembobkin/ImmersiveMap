// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public protocol ImmersiveMapTileProvider: Sendable {
    var id: String { get }
    var cacheNamespace: String { get }
    var configurationFingerprint: UInt64 { get }
    var tileSource: ImmersiveMapTileSource { get }
    var maximumTileZoomLevel: Int? { get }
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

    private let labelProviderProfileFactory: @Sendable (ImmersiveMapSettings) -> any VectorTileLabelProviderProfile

    public init<P: ImmersiveMapTileProvider>(_ provider: P) {
        self.id = provider.id
        self.cacheNamespace = provider.cacheNamespace
        self.configurationFingerprint = provider.configurationFingerprint
        self.tileSource = provider.tileSource
        self.maximumTileZoomLevel = provider.maximumTileZoomLevel

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

    public init(id: String,
                cacheNamespace: String? = nil,
                tileSource: ImmersiveMapTileSource,
                labelProfile: ImmersiveMapVectorTileLabelProfile = .generic,
                maximumTileZoomLevel: Int? = nil,
                configurationFingerprint: UInt64? = nil) {
        self.id = id
        self.cacheNamespace = cacheNamespace ?? id
        self.tileSource = tileSource
        self.labelProfile = labelProfile
        self.maximumTileZoomLevel = maximumTileZoomLevel
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
