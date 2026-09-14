// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What a line or surface feature is as a road, beyond how it draws: what
/// kind of road thing it is (a centreline, a carriageway surface, a
/// parking lot, measured paint), where it sits (in a tunnel, on the
/// ground, on a bridge, and on which `layer`) and which street it is a
/// piece of. The schema reading (`ImmersiveMapTileSchema`) states these;
/// the engine orders the roads, clips them against the carriageway
/// surfaces and stitches the pieces of a street from them, and the style
/// draws by them. Neither reads a road tag itself.
///
/// A feature that is not a road (a river, a border) has no road facts at
/// all.
public struct ImmersiveMapRoadFacts: Equatable, Sendable {
    /// The kind of road thing a feature is.
    public enum Kind: Equatable, Sendable {
        /// A road's own line: the centreline the ribbon is drawn along.
        case centreline
        /// A carriageway surface polygon (a junction area, a stretch of
        /// carriageway): the roadway as an area, which the ribbons that
        /// enter it run under. `reconstructed` is true for a surface
        /// computed from the road graph, false for one mapped by hand.
        case surface(reconstructed: Bool)
        /// A surface parking lot, with its bays parallel to the kerb (a
        /// car length apart) or perpendicular to it.
        case parkingLot(baysParallel: Bool)
        /// Paint the source measured on the ground and shipped as its own
        /// line (a lane line, a stop line, a crossing). It already ends
        /// exactly where it ends on the ground, so the engine's road
        /// machinery leaves it alone: no clipping against carriageway
        /// surfaces, no junction making, no stitching.
        case paint(ImmersiveMapRoadPaint)
    }

    public var kind: Kind
    /// The physical structure a road runs on, as the source tags it. A
    /// road that ships only a negative or positive `layer` is on the
    /// ground by this reading, below or above its neighbours: a street
    /// diving under a bridge is not in a tunnel, and is in full view from
    /// above.
    public enum Structure: Sendable {
        case tunnel
        case ground
        case bridge
    }

    public var structure: Structure
    /// The vertical layer among roads of one structure, the source's
    /// `layer`: a bridge over a bridge, a road under a road.
    public var layer: Int
    /// The identity of the street the feature is a piece of, as the source
    /// states it: an id assembled from the whole road network before the
    /// tiles were cut, so it holds across a tile boundary. Empty when the
    /// source states none. Two surfaces of one street have the slit between
    /// them paved.
    public var streetIdentity: String
    /// The road's name, empty when it has none. The fallback identity of a
    /// street for counting junctions where the source states no
    /// `streetIdentity`.
    public var name: String
    /// The key two pieces must share to be drawn as one ribbon with no seam
    /// where they met: the street they belong to plus everything that
    /// changes how a piece draws. Nil for a piece that is never stitched.
    public var stitchingKey: String?
    /// The feature is a carriageway surface the engine found to be the roof
    /// of a tunnel (`RoadTunnelSurfaceResolver`): the surface ships no
    /// tunnel tag of its own, only the tunnel's `layer`. Set by the engine,
    /// never by a schema reading, and the one fact the engine adds.
    public var isTunnelRoof: Bool
    /// The name laid along the road, nil for a road without one.
    public var label: ImmersiveMapLabelFacts?

    public init(kind: Kind = .centreline,
                structure: Structure = .ground,
                layer: Int = 0,
                streetIdentity: String = "",
                name: String = "",
                stitchingKey: String? = nil,
                isTunnelRoof: Bool = false,
                label: ImmersiveMapLabelFacts? = nil) {
        self.kind = kind
        self.structure = structure
        self.layer = layer
        self.streetIdentity = streetIdentity
        self.name = name
        self.stitchingKey = stitchingKey
        self.isTunnelRoof = isTunnelRoof
        self.label = label
    }

    /// A road on the ground with no identity.
    public static let ground = ImmersiveMapRoadFacts()

    /// The feature is in a tunnel: a road that runs underground, or a
    /// surface found to be a tunnel's roof.
    public var isTunnel: Bool {
        structure == .tunnel || isTunnelRoof
    }

    /// A carriageway surface or a parking lot: an area of roadway.
    public var isSurface: Bool {
        switch kind {
        case .surface, .parkingLot:
            return true
        case .centreline, .paint:
            return false
        }
    }

    public var isShippedPaint: Bool {
        if case .paint = kind { return true }
        return false
    }

    /// The paint the feature is, nil for anything that is not paint.
    public var paint: ImmersiveMapRoadPaint? {
        if case .paint(let paint) = kind { return paint }
        return nil
    }
}

/// A line of paint the source measured on the ground: what it marks, the
/// colour the source states for it, and whether it is dashed where the
/// source says.
public struct ImmersiveMapRoadPaint: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A pedestrian crossing, painted (`marked`) or not.
        case crossing(marked: Bool)
        /// The line between the two directions of travel.
        case dividingLine
        /// A line between lanes of one direction.
        case laneSeparator
        /// The line along the edge of the carriageway.
        case edgeLine
        /// The axis of a dedicated bus lane.
        case busLane
        /// The stretch of kerb at a bus stop.
        case busStopKerb
        /// A kind the reading does not know, with the source's word for it.
        case other(String)
    }

    public var kind: Kind
    /// The source says the paint is yellow; white otherwise.
    public var isYellow: Bool
    /// Whether the line is dashed, nil where the source does not say.
    public var isDashed: Bool?

    public init(kind: Kind, isYellow: Bool = false, isDashed: Bool? = nil) {
        self.kind = kind
        self.isYellow = isYellow
        self.isDashed = isDashed
    }
}
