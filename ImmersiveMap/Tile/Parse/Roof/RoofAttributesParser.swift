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

        return RoofInfo(height: roofHeight,
                        shape: shape,
                        orientation: parseOrientation(attributes: attributes),
                        directionDegrees: parseDirection(attributes: attributes,
                                                        numericParser: numericParser))
    }

    private func parseShape(attributes: [String: VectorTile_Tile.Value]) -> RoofShape {
        guard let value = attributes["roof:shape"], value.hasStringValue else { return .unknown }
        let raw = value.stringValue.lowercased()
        let normalized = raw.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "flat":
            return .flat
        case "gabled", "gable", "gambrel":
            return .gabled
        case "hipped", "hip", "mansard":
            return .hipped
        case "pyramid", "pyramidal":
            return .pyramid
        case "cone", "conical":
            return .cone
        case "dome", "round", "onion", "halfdome":
            return .dome
        case "skillion", "shed", "lean", "leaning":
            return .skillion
        default:
            return .unknown
        }
    }

    private func parseOrientation(attributes: [String: VectorTile_Tile.Value]) -> RoofOrientation? {
        guard let value = attributes["roof:orientation"], value.hasStringValue else { return nil }
        switch value.stringValue.lowercased() {
        case "along":
            return .along
        case "across":
            return .across
        default:
            return nil
        }
    }

    private func parseDirection(attributes: [String: VectorTile_Tile.Value],
                                numericParser: (VectorTile_Tile.Value) -> Float?) -> Float? {
        guard let value = attributes["roof:direction"] else { return nil }
        if let degrees = numericParser(value) {
            return degrees
        }
        guard value.hasStringValue else { return nil }
        // OSM also allows compass points for roof:direction.
        switch value.stringValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "n": return 0
        case "nne": return 22.5
        case "ne": return 45
        case "ene": return 67.5
        case "e": return 90
        case "ese": return 112.5
        case "se": return 135
        case "sse": return 157.5
        case "s": return 180
        case "ssw": return 202.5
        case "sw": return 225
        case "wsw": return 247.5
        case "w": return 270
        case "wnw": return 292.5
        case "nw": return 315
        case "nnw": return 337.5
        default: return nil
        }
    }
}
