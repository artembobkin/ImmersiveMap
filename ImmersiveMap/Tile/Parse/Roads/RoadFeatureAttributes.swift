// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// What a road feature's attributes say about where it sits: its physical
/// structure (tunnel, ground, bridge), its `layer`, and the class tiers the
/// styles' class priorities are read against.
enum RoadFeatureAttributes {
    /// Styles state a class priority per road; from this value up the road is
    /// part of the automobile network and draws in the tier above the
    /// pedestrian one. The built-in style puts service roads at 45 and paths
    /// at 35 with rail between; a custom style with a priority lands in the
    /// tier its number implies.
    static let automobileRoadClassPriorityFloor = 45

    /// The class from which a road makes a junction for the paint on another
    /// one: `minor`, the lowest class that is a street rather than a way onto
    /// a plot. A service driveway, a parking aisle and a footway meeting an
    /// avenue leave its markings running, because on the ground they do.
    static let markingJunctionClassPriorityFloor = 50

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
    /// avenue never lies over its kerb. The class priority the style states
    /// is the tier line: drive tiers sit at 45 and above, footways, tracks
    /// and rail below.
    static func drawStructure(physical: RoadStructureKind, classPriority: Int) -> RoadStructureKind {
        physical == .ground && classPriority >= automobileRoadClassPriorityFloor
            ? .automobileGround
            : physical
    }
}
