// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public struct ImmersiveMapVectorTileLabelProfile: Equatable, Sendable {
    public static let generic = ImmersiveMapVectorTileLabelProfile(
        textKeys: ["name:en"],
        rankKeys: ["rank", "sort_rank", "labelrank", "sizerank", "symbolrank"],
        kindKeys: ["class", "type"]
    )

    public var textKeys: [String]
    public var rankKeys: [String]
    public var kindKeys: [String]
    public var pointLabelLayers: Set<String>?
    public var excludedPointLabelLayers: Set<String>
    public var houseNumberLayers: Set<String>
    public var houseNumberTextKeys: [String]
    public var usesFeatureIdentity: Bool

    public init(textKeys: [String] = ImmersiveMapVectorTileLabelProfile.generic.textKeys,
                rankKeys: [String] = ImmersiveMapVectorTileLabelProfile.generic.rankKeys,
                kindKeys: [String] = ImmersiveMapVectorTileLabelProfile.generic.kindKeys,
                pointLabelLayers: Set<String>? = nil,
                excludedPointLabelLayers: Set<String> = [],
                houseNumberLayers: Set<String> = [],
                houseNumberTextKeys: [String] = [],
                usesFeatureIdentity: Bool = true) {
        self.textKeys = Self.normalizedKeys(textKeys)
        self.rankKeys = Self.normalizedKeys(rankKeys)
        self.kindKeys = Self.normalizedKeys(kindKeys)
        self.pointLabelLayers = pointLabelLayers.map(Self.normalizedLayers)
        self.excludedPointLabelLayers = Self.normalizedLayers(excludedPointLabelLayers)
        self.houseNumberLayers = Self.normalizedLayers(houseNumberLayers)
        self.houseNumberTextKeys = Self.normalizedKeys(houseNumberTextKeys)
        self.usesFeatureIdentity = usesFeatureIdentity
    }

    var cacheFingerprint: UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine("ImmersiveMapVectorTileLabelProfile")
        combine(textKeys, into: &hasher)
        combine(rankKeys, into: &hasher)
        combine(kindKeys, into: &hasher)
        if let pointLabelLayers {
            hasher.combine("pointLabelLayers")
            combine(pointLabelLayers.sorted(), into: &hasher)
        }
        combine(excludedPointLabelLayers.sorted(), into: &hasher)
        combine(houseNumberLayers.sorted(), into: &hasher)
        combine(houseNumberTextKeys, into: &hasher)
        hasher.combine(usesFeatureIdentity ? "featureIdentity" : "tileLocalIdentity")
        return hasher.finalize()
    }

    func includesPointLabelLayer(_ layerName: String) -> Bool {
        let normalizedLayerName = Self.normalizedLayer(layerName)
        guard excludedPointLabelLayers.contains(normalizedLayerName) == false else {
            return false
        }
        guard let pointLabelLayers else {
            return true
        }
        return pointLabelLayers.contains(normalizedLayerName)
    }

    private func combine(_ values: [String], into hasher: inout StableFNV1aHasher) {
        hasher.combine(String(values.count))
        for value in values {
            hasher.combine(value)
        }
    }

    private static func normalizedKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.compactMap { key in
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty == false, seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func normalizedLayers(_ layers: Set<String>) -> Set<String> {
        Set(layers.compactMap { layer in
            let normalized = normalizedLayer(layer)
            return normalized.isEmpty ? nil : normalized
        })
    }

    private static func normalizedLayer(_ layerName: String) -> String {
        layerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
