// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt
import simd

/// Reads the carriageway surfaces of a road layer (junction areas, parking
/// lots, the paved slits between pieces of one street) into the road
/// phases: a surface is drawn under the style's fill pass as its
/// triangulated polygon and under the casing pass as its outline, a closed
/// kerb, and a parking lot's detail pass is the comb of bay stripes.
///
/// Stateless across tiles: the per-tile tessellators come in as arguments.
struct RoadSurfaceAreaReader {
    private let parkingBayBuilder = ParkingBayGeometryBuilder()
    private let tileExtent = Float(TileCoordinateSpace.tileExtentDouble)

    /// Puts a carriageway-surface polygon (a junction area) into the road
    /// phases: the triangulated polygon under the style's fill pass, and each
    /// ring, closed, tessellated as a kerb under the casing pass. Both carry
    /// the style's class priority so they sort among the roads of that class:
    /// the surface is drawn after the ribbons' casings of its class and under
    /// their fills, exactly where a ribbon's own fill would go, so the ribbons
    /// entering the junction merge into it and their kerbs stop at its edge.
    /// `parsedGeometry.clipped` and `surfaceAreas` are all TILE space (y
    /// down); only `parsedGeometry.parsedPolygon` (the fill) is already
    /// tessellated render-space vertices.
    func append(parsedGeometry: ParsePolygon.ParsedGeometry,
                road: ImmersiveMapRoadFacts,
                style: RoadStyle,
                tile: Tile,
                surfaceAreas: [RoadSurfaceArea],
                tools: TileParseTools,
                into result: inout ReadingStageResult) {
        let clippedExterior = parsedGeometry.clipped.exterior
        let clippedInteriors = parsedGeometry.clipped.interiors
        let physicalStructure = RoadStructureKind(level: style.level)
        let structure = RoadStructureKind(level: style.level, tier: style.tier)
        let layer = road.layer
        for roadPass in style.orderedPasses {
            let pass = roadPass.pass
            result.registerRoadStyle(BakedStyle(pass: pass), key: pass.key)
            var polygons: [ParsedPolygon] = []
            switch roadPass.role {
            case .fill:
                polygons = [parsedGeometry.parsedPolygon]
            case .casing:
                // Each ring as a closed line: the first two points repeat at
                // the end so the closing corner gets a join like every other.
                //
                // The rings arrive in tile space (`ParsedGeometry.clipped`
                // keeps the Parse layer's working space) and go straight to
                // the line tessellator, which owns the one flip into render
                // space. This used to be a round trip of three flips, and one
                // shipped kerb was drawn mirrored about the tile's mid-line.
                for ring in [clippedExterior] + clippedInteriors where ring.count >= 3 {
                    var closed = ring
                    closed.append(ring[0])
                    closed.append(ring[1])
                    if let kerb = tools.parseLine.parse(points: closed,
                                                        width: pass.lineGeometry.lineWidth,
                                                        tileExtent: tileExtent,
                                                        startCapRound: false,
                                                        endCapRound: false,
                                                        lineJoinRound: true,
                                                        clipGeometryToTileBounds: true) {
                        polygons.append(kerb)
                    }
                }
            case .detail:
                guard case .parkingBays(let bays) = style.decoration else { continue }
                // The parking-bay comb: short stripes laid out by the
                // builder in tile space (the ring already is), each
                // tessellated as its own point-locked stroke with hard ends.
                let unitsPerMetre = ParkingBayGeometryBuilder.tileUnitsPerMetre(tile: tile)
                var baysParallel = false
                if case .parkingLot(let parallel) = road.kind {
                    baysParallel = parallel
                }
                var stripes = parkingBayBuilder.buildStripes(
                    exterior: clippedExterior,
                    unitsPerMetre: unitsPerMetre,
                    parallel: baysParallel,
                    layout: bays
                )
                // Where a carriageway, a junction or a bus lane overlaps the
                // lot, that ground is theirs: the comb ends at their edge
                // instead of climbing onto the roadway.
                let owners = surfaceAreas.filter {
                    $0.classPriority > style.classPriority
                        && $0.structureKind == physicalStructure
                }
                if owners.isEmpty == false {
                    stripes = stripes.flatMap { RoadSurfaceClipper.clip(polyline: $0, outside: owners) }
                        .filter { stripe in
                            guard let first = stripe.first, let last = stripe.last else { return false }
                            return simd_distance(first, last) >= bays.minimumStripeMetres * unitsPerMetre
                        }
                }
                for stripe in stripes {
                    if let stroke = tools.parseLine.parse(points: stripe,
                                                          width: pass.lineGeometry.lineWidth,
                                                          tileExtent: tileExtent,
                                                          startCapRound: false,
                                                          endCapRound: false,
                                                          lineJoinRound: false,
                                                          clipGeometryToTileBounds: true) {
                        polygons.append(stroke)
                    }
                }
            default:
                continue
            }
            for polygon in polygons {
                result.appendRoad(polygon,
                                  key: pass.key,
                                  structureKind: structure,
                                  layer: layer,
                                  classPriority: style.classPriority,
                                  passRole: roadPass.role)
            }
        }
    }

    /// The paved slits between trimmed pieces of one street: each quad draws
    /// exactly like a carriageway surface, with the style and attributes of
    /// the piece it touches, so the roadway is continuous across the joint
    /// and the trims' kerbs disappear under the fills.
    func appendSurfaceBridges(roads: RoadLayerPrecomputation,
                              featureFacts: [ImmersiveMapFeatureFacts],
                              featureStyles: [FeatureStyle],
                              tile: Tile,
                              tools: TileParseTools,
                              into result: inout ReadingStageResult) {
        for bridge in roads.surfaceBridges {
            let owner = roads.surfaceAreas[bridge.ownerAreaIndex]
            guard owner.featureIndex >= 0, owner.featureIndex < featureStyles.count,
                  let road = featureFacts[owner.featureIndex].road,
                  let style = featureStyles[owner.featureIndex].roadStyle else { continue }
            let ringPoints = bridge.ring.map {
                Point(x: Int32($0.x.rounded()), y: Int32($0.y.rounded()))
            }
            guard let parsedGeometry = tools.parsePolygon.parseGeometry(polygon: Polygon(exteriorRing: ringPoints,
                                                                                        interiorRings: []),
                                                                        tileExtent: tileExtent) else {
                continue
            }
            append(parsedGeometry: parsedGeometry,
                   road: road,
                   style: style,
                   tile: tile,
                   surfaceAreas: roads.surfaceAreas,
                   tools: tools,
                   into: &result)
        }
    }
}
