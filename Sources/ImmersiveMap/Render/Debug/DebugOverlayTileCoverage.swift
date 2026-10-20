// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// The frame's tile coverage seen from above, for the debug panel's
/// coverage map: every placement as the square of its slot, the ground
/// footprint of the view, the point the camera looks at and the eye, all
/// in normalized Mercator (x east and y south, the world one unit wide,
/// a copy of the world to the east one unit further). The map draws the
/// rings as they are, nested bands of squares round the look-at point,
/// which the perspective of the map itself folds into a few pixels at
/// the horizon.
struct DebugOverlayTileCoverage: Equatable {
    struct Placement: Equatable {
        /// The slot drawn: its square and its colour.
        let slot: Tile
        /// The tile drawn in it: the slot's own, or a coarser stand-in.
        let source: Tile
        let worldWrap: Int8

        var isStandIn: Bool { slot != source }

        /// The slot's square in normalized Mercator.
        var square: CGRect {
            let count = Double(1 << slot.z)
            return CGRect(x: Double(slot.x) / count + Double(worldWrap),
                          y: Double(slot.y) / count,
                          width: 1 / count,
                          height: 1 / count)
        }
    }

    let placements: [Placement]
    /// The ground footprint of the view, a convex polygon, empty on the
    /// globe.
    let footprint: [SIMD2<Double>]
    /// The point the camera looks at.
    let center: SIMD2<Double>
    /// Where the eye stands over the ground, nil on the globe.
    let eye: SIMD2<Double>?

    /// The frame's coverage: the flat map's footprint and eye, the globe's
    /// placements alone.
    static func make(frameContext: FrameContext) -> DebugOverlayTileCoverage {
        let placements = placements(of: frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements)
        let center = frameContext.mapCameraState.centerWorldMercator
        guard frameContext.renderSurfaceMode == .flat else {
            return DebugOverlayTileCoverage(placements: placements, footprint: [], center: center, eye: nil)
        }
        let flat = frameContext.flatRenderState
        let footprint = CoveragePolygonBuilder.make(cameraMatrix: frameContext.cameraMatrices.projectionView)?.vertices
            .map { mercator(flatWorld: SIMD2<Double>(Double($0.x), Double($0.y)), flatRenderState: flat) } ?? []
        let eye = mercator(flatWorld: SIMD2<Double>(Double(frameContext.cameraEye.x), Double(frameContext.cameraEye.y)),
                           flatRenderState: flat)
        return DebugOverlayTileCoverage(placements: placements, footprint: footprint, center: center, eye: eye)
    }

    /// The frame's placements as the map shows them, without the flat
    /// map's horizon backdrop (`PlaceTile.isHorizonBackdrop`): the world
    /// tile under everything is no ground of the planner's, and its
    /// square, the whole world, would be the map's window, with the
    /// placements the map is there to show a few pixels in it.
    static func placements(of placeTiles: [PlaceTile]) -> [Placement] {
        placeTiles.compactMap {
            guard $0.isHorizonBackdrop == false else { return nil }
            return Placement(slot: $0.placeIn.tile, source: $0.metalTile.tile, worldWrap: $0.placeIn.worldWrap)
        }
    }

    /// A point of the flat render world (y up, the world `renderMapSize`
    /// wide and panned by `pan`) in normalized Mercator: the inverse of
    /// `ImmersiveMapProjection.flatTileOriginAndSize` at zoom 0.
    static func mercator(flatWorld point: SIMD2<Double>, flatRenderState: FlatRenderState) -> SIMD2<Double> {
        let size = flatRenderState.renderMapSize
        let half = size * 0.5
        let x = (point.x + half - flatRenderState.pan.x * half) / size
        let y = 1 - (point.y + half + flatRenderState.pan.y * half) / size
        return SIMD2<Double>(x, y)
    }
}

/// The geometry of the coverage map, shared by the platform views, which
/// draw it by hand: the window of Mercator it shows and where a point of
/// Mercator lands in it.
enum DebugOverlayTileCoverageLayout {
    static let side: CGFloat = 280
    static let margin: Double = 0.06
    static let cornerRadius: CGFloat = 8
    static let tileLineWidth: CGFloat = 1.5
    static let tileFillAlpha: CGFloat = 0.26
    static let footprintLineWidth: CGFloat = 1.5
    static let footprintFillAlpha: CGFloat = 0.08
    static let markerRadius: CGFloat = 3.5
    static let labelFontSize: CGFloat = 9
    /// A slot square narrower than this on the map carries no label.
    static let labelledSquareSide: CGFloat = 44
    static let sourceLabelledSquareSide: CGFloat = 60

    /// The square of Mercator shown: the bounds of every slot and of the
    /// point the camera looks at, widened by `margin`, squared round its
    /// centre, so the map is never stretched and the north stays up. The
    /// footprint is left out on purpose: a camera on the horizon sees to
    /// the far plane, and a window round that put the tiles in a corner
    /// a few pixels wide. It is cut at the window's edge instead.
    static func window(for coverage: DebugOverlayTileCoverage) -> CGRect {
        var bounds = CGRect(x: coverage.center.x, y: coverage.center.y, width: 0, height: 0)
        for placement in coverage.placements { bounds = bounds.union(placement.square) }
        guard bounds.width > 0 || bounds.height > 0 else {
            return CGRect(x: coverage.center.x - 0.5, y: coverage.center.y - 0.5, width: 1, height: 1)
        }
        let side = max(bounds.width, bounds.height) * (1 + margin * 2)
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    /// Where a point of Mercator lands in a map of `side` points, y down
    /// as Mercator's.
    static func point(_ mercator: SIMD2<Double>, window: CGRect, side: CGFloat) -> CGPoint {
        let scale = side / max(window.width, 1e-12)
        return CGPoint(x: (mercator.x - window.minX) * scale, y: (mercator.y - window.minY) * scale)
    }

    static func rect(_ square: CGRect, window: CGRect, side: CGFloat) -> CGRect {
        let origin = point(SIMD2<Double>(square.minX, square.minY), window: window, side: side)
        let scale = side / max(window.width, 1e-12)
        return CGRect(x: origin.x, y: origin.y, width: square.width * scale, height: square.height * scale)
    }

    /// The placements in drawing order: the coarse slots first, so a fine
    /// slot lies on the coarse one it splits.
    static func drawingOrder(_ placements: [DebugOverlayTileCoverage.Placement]) -> [DebugOverlayTileCoverage.Placement] {
        placements.sorted { a, b in
            if a.slot.z != b.slot.z { return a.slot.z < b.slot.z }
            if a.slot.x != b.slot.x { return a.slot.x < b.slot.x }
            return a.slot.y < b.slot.y
        }
    }
}
