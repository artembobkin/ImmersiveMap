// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

final class RoofAttributesParser {
    private let levelHeight: Float

    init(levelHeight: Float = 2.5) {
        self.levelHeight = levelHeight
    }

    func parse(attributes: [String: VectorTile_Tile.Value],
               numericParser: (VectorTile_Tile.Value) -> Float?) -> RoofInfo? {
        let rawRoofHeight = attributes["roof:height"].flatMap(numericParser)
        let rawRoofLevels = attributes["roof:levels"].flatMap(numericParser)
        let roofHeight = rawRoofHeight ?? rawRoofLevels.map { $0 * levelHeight } ?? 0
        guard roofHeight > 0 else { return nil }

        let shape = parseShape(attributes: attributes)
        guard shape != .flat && shape != .unknown else { return nil }

        return RoofInfo(height: roofHeight, shape: shape)
    }

    private func parseShape(attributes: [String: VectorTile_Tile.Value]) -> RoofShape {
        guard let value = attributes["roof:shape"], value.hasStringValue else { return .unknown }
        let raw = value.stringValue.lowercased()
        let normalized = raw.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "flat":
            return .flat
        case "gabled", "gable":
            return .gabled
        case "hipped", "hip":
            return .hipped
        case "pyramid", "pyramidal":
            return .pyramid
        case "cone", "conical":
            return .cone
        case "dome", "round", "onion":
            return .dome
        case "skillion", "shed", "lean", "leaning":
            return .skillion
        default:
            return .unknown
        }
    }
}
