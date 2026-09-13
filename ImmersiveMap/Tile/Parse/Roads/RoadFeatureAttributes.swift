// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// What a road feature's attributes say about where it sits: its physical
/// structure (tunnel, ground, bridge) and its `layer`.
enum RoadFeatureAttributes {
    /// The physical structure, read from either schema's spelling of tunnel
    /// and bridge and from the sign of `layer`.
    static func structureKind(attributes: [String: MvtValue]) -> RoadStructureKind {
        let locationValue = attributes["location"]?.stringValue?.lowercased() ?? ""
        let structureValue = attributes["structure"]?.stringValue?.lowercased() ?? ""
        let brunnelValue = attributes["brunnel"]?.stringValue?.lowercased() ?? ""
        let layerValue = attributes["layer"]?.integerValue ?? 0

        let isTunnel = MvtValue.isTruthy(attributes["underground"])
            || MvtValue.isTruthy(attributes["tunnel"])
            || locationValue.contains("underground")
            || locationValue.contains("subterranean")
            || locationValue.contains("tunnel")
            || locationValue.contains("underwater")
            || structureValue == "tunnel"
            || brunnelValue == "tunnel"
            || layerValue < 0
        if isTunnel {
            return .tunnel
        }

        let isBridge = MvtValue.isTruthy(attributes["bridge"])
            || structureValue == "bridge"
            || brunnelValue == "bridge"
            || locationValue.contains("bridge")
            || locationValue.contains("elevated")
            || layerValue > 0
        if isBridge {
            return .bridge
        }

        return .ground
    }

    /// The `layer` value, 0 when the feature carries none.
    static func layer(attributes: [String: MvtValue]) -> Int {
        attributes["layer"]?.integerValue ?? 0
    }

    /// Where a line draws: on the ground the automobile network draws as
    /// its own tier above the pedestrian one, so a path ending against an
    /// avenue never lies over its kerb. Which tier is the style's decision.
    static func drawStructure(physical: RoadStructureKind, tier: RoadTier) -> RoadStructureKind {
        physical == .ground && tier == .automobile
            ? .automobileGround
            : physical
    }
}
