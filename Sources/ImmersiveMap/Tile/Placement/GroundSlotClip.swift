// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The ground a placement draws on the flat map: the rectangles of its
/// slot in the source tile's local units, which the vertex stage clips the
/// source's geometry to (Tile.metal and TileRaster.metal, vertex buffer
/// 12, four clip distances).
///
/// The ground is partitioned on the CPU, so the GPU has only the depth to
/// test: every placement draws its slot and nothing else, the slot being
/// the target tile's extent within its ring's band (inside the band's
/// outer square, but for the last band's, outside the inner one, the
/// finer band's), so no two placements draw the same ground and the depth
/// alone orders what is seen, on the plane and on a relief alike, where a
/// coarser stand-in's near ridge and a finer tile's far slope meet at one
/// pixel as different ground and the nearer is the one to see. A source
/// placed in several slots, a parent standing in for its children, draws
/// once per slot. A descendant standing in draws its own extent, which
/// lies inside the slot, and an ancestor standing in the same slot draws
/// around it. A band's tile that straddles the band's squares is cut at
/// them, into up to four pieces, and the neighbouring band's tile over the
/// same ground is cut at the same line.
enum GroundSlotClip {
    /// A placement and the rectangles it draws.
    struct Placement {
        let placeTile: PlaceTile
        let clips: [SIMD4<Float>]
    }

    /// The frame's placements with their rectangles, those with nothing
    /// to draw left out. An ancestor standing in a slot draws around the
    /// descendants placed in the same slot.
    static func placements(_ placeTiles: [PlaceTile], rings: Rings) -> [Placement] {
        var descendantsBySlot: [VisibleTile: [Tile]] = [:]
        for placeTile in placeTiles where placeTile.inOwnSlot && placeTile.metalTile.tile != placeTile.slot.tile {
            descendantsBySlot[placeTile.slot, default: []].append(placeTile.metalTile.tile)
        }
        var placements: [Placement] = []
        placements.reserveCapacity(placeTiles.count)
        for placeTile in placeTiles {
            let holes = placeTile.inOwnSlot ? [] : descendantsBySlot[placeTile.slot] ?? []
            let clips = rects(source: placeTile.metalTile.tile, slot: placeTile.slot, holes: holes, rings: rings)
            if clips.isEmpty == false {
                placements.append(Placement(placeTile: placeTile, clips: clips))
            }
        }
        return placements
    }

    /// A rectangle nothing is clipped by.
    static let unclipped = SIMD4<Float>(-1e9, -1e9, 1e9, 1e9)

    /// The frame's rings: the bands as the coverage resolved them, nearest
    /// first, the target zoom their distances are counted in, and the
    /// plane they lie on.
    struct Rings {
        let targetZoom: Int
        let bands: [FlatRingBand]
        let flatRenderState: FlatRenderState
    }

    /// The rectangles of `slot` the source draws, in the source's local
    /// units (0 to 4096 a side, y north): the slot cut to its band, less
    /// the `holes` (the extents of tiles drawn in the slot over it), then
    /// to the source's own extent. Empty where the source has nothing to
    /// draw in the slot.
    static func rects(source: Tile, slot: VisibleTile, holes: [Tile] = [], rings: Rings) -> [SIMD4<Float>] {
        let state = rings.flatRenderState
        let slotExtent = extent(of: slot.tile, worldWrap: slot.worldWrap, state: state)
        let sourceExtent = extent(of: source, worldWrap: slot.worldWrap, state: state)
        var pieces: [FlatRingSquare] = [slotExtent]
        // The slot's band: the bands of its zoom, which are consecutive
        // (the bands are nearest first, their zooms never rising) and may
        // be several where the rules' zooms meet the floor, so they count
        // as one band, from the first's inner square to the last's outer.
        if let first = rings.bands.firstIndex(where: { $0.zoom == slot.z }),
           let last = rings.bands.lastIndex(where: { $0.zoom == slot.z }) {
            let shift = Double(slot.worldWrap) * state.renderMapSize
            // The band's outer square cuts the slot where the next band
            // takes over. The last band has no next: its tiles draw whole
            // past their square, to the horizon, as the plane's do.
            if last < rings.bands.count - 1 {
                let outer = shifted(FlatRingRuleCoverage.square(rings: rings.bands[last].distance,
                                                                targetZoom: rings.targetZoom,
                                                                flatRenderState: state), by: shift)
                pieces = pieces.compactMap { intersection($0, outer) }
            }
            if first > 0 {
                let inner = shifted(FlatRingRuleCoverage.square(rings: rings.bands[first - 1].distance,
                                                                targetZoom: rings.targetZoom,
                                                                flatRenderState: state), by: shift)
                pieces = pieces.flatMap { subtracting(inner, from: $0) }
            }
        }
        for hole in holes {
            let holeExtent = extent(of: hole, worldWrap: slot.worldWrap, state: state)
            pieces = pieces.flatMap { subtracting(holeExtent, from: $0) }
        }
        return pieces.compactMap { intersection($0, sourceExtent) }.map { local($0, in: sourceExtent) }
    }

    private static func extent(of tile: Tile, worldWrap: Int8, state: FlatRenderState) -> FlatRingSquare {
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: tile.z, worldWrap: worldWrap,
                                                                  flatRenderPan: state.pan, renderMapSize: state.renderMapSize)
        return FlatRingSquare(minX: Double(origin.x), minY: Double(origin.y),
                              maxX: Double(origin.x) + Double(origin.z), maxY: Double(origin.y) + Double(origin.z))
    }

    private static func shifted(_ square: FlatRingSquare, by shift: Double) -> FlatRingSquare {
        FlatRingSquare(minX: square.minX + shift, minY: square.minY, maxX: square.maxX + shift, maxY: square.maxY)
    }

    /// The part of `a` inside `b`, nil when there is none to speak of.
    static func intersection(_ a: FlatRingSquare, _ b: FlatRingSquare) -> FlatRingSquare? {
        let square = FlatRingSquare(minX: max(a.minX, b.minX), minY: max(a.minY, b.minY),
                                    maxX: min(a.maxX, b.maxX), maxY: min(a.maxY, b.maxY))
        guard square.maxX - square.minX > 1e-9, square.maxY - square.minY > 1e-9 else { return nil }
        return square
    }

    /// `rect` less `hole`: the rectangle whole when they do not meet, else
    /// the frame around the hole in up to four pieces, the two full-height
    /// sides and the top and the bottom between them.
    static func subtracting(_ hole: FlatRingSquare, from rect: FlatRingSquare) -> [FlatRingSquare] {
        guard let cut = intersection(hole, rect) else { return [rect] }
        let strips = [FlatRingSquare(minX: rect.minX, minY: rect.minY, maxX: cut.minX, maxY: rect.maxY),
                      FlatRingSquare(minX: cut.maxX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY),
                      FlatRingSquare(minX: cut.minX, minY: cut.maxY, maxX: cut.maxX, maxY: rect.maxY),
                      FlatRingSquare(minX: cut.minX, minY: rect.minY, maxX: cut.maxX, maxY: cut.minY)]
        return strips.filter { $0.maxX - $0.minX > 1e-9 && $0.maxY - $0.minY > 1e-9 }
    }

    /// The rectangle in the local units of a tile of `extent`.
    private static func local(_ rect: FlatRingSquare, in extent: FlatRingSquare) -> SIMD4<Float> {
        let scale = 4096.0 / (extent.maxX - extent.minX)
        return SIMD4<Float>(Float((rect.minX - extent.minX) * scale), Float((rect.minY - extent.minY) * scale),
                            Float((rect.maxX - extent.minX) * scale), Float((rect.maxY - extent.minY) * scale))
    }
}
