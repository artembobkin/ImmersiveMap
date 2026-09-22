// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt
import simd

/// A road line decoded, converted, and exact-clipped once: the pre-pass
/// counts shared endpoints from it and the line reader tessellates from it,
/// so the geometry work is not repeated per pass.
struct PreparedRoadLine {
    let points: [SIMD2<Float>]
    let exactFragments: [ClippedLineFragment]
}

/// A carriageway-surface polygon (a junction area) of a road layer, as a
/// ring in RAW tile space (y down, the space the road lines are in until
/// the tessellators flip them), with the road class priority it draws at.
/// A ribbon of the same or a lower class that runs inside one is clipped
/// away there: the surface owns that ground.
struct RoadSurfaceArea {
    let exterior: [SIMD2<Float>]
    let classPriority: Int
    let bounds: (min: SIMD2<Float>, max: SIMD2<Float>)
    /// The physical structure the surface belongs to. A surface owns only
    /// the roads of its own structure and layer: a bridge deck polygon
    /// must not clip the street running under it on the ground, and a
    /// ground surface must not clip the deck above.
    var structureKind: RoadStructureKind = .ground
    var layer: Int = 0
    /// The surface cuts the shipped paint inside it too
    /// (`RoadSurfacePaintRule.cutsAll`): a tunnel's roof is a bare fill.
    var cutsShippedPaint: Bool = false
    /// The surface cuts the styled paint of the roads inside it
    /// (`RoadSurfacePaintRule.cutsStyled` or `cutsAll`).
    var cutsPaint: Bool = false
    /// The street identity of the piece as the style read it, empty when
    /// the source ships none. Only the gap bridger reads it: a slit is
    /// paved only between two pieces of the SAME street.
    var street: String = ""
    /// The feature the surface was decoded from, -1 for a paving quad
    /// the bridger made: the paving inherits this feature's style.
    var featureIndex: Int = -1
}

/// What the separate-road path knows about a whole road layer before any
/// of its features is read: every line clipped by the carriageway surfaces
/// and stitched into streets, the connections counted, the slits between
/// surface pieces paved. Built once per road layer at street zooms, and
/// `empty` for every other layer.
struct RoadLayerPrecomputation {
    let sharedPointCounts: [RoadConnectionPointKey: Int]
    /// The lines a feature's PAINT is built from: the same raw lines,
    /// but clipped only by the surfaces that cut paint (junctions
    /// reconstructed from the graph), not by every surface. A hand-mapped
    /// carriageway area covers a whole street, and a street inside one
    /// keeps its paint; a crossing does not.
    let paintLinesByFeatureIndex: [[PreparedRoadLine]]
    let linesByFeatureIndex: [[PreparedRoadLine]]
    /// The layer's carriageway surfaces, the paving quads included.
    let surfaceAreas: [RoadSurfaceArea]
    /// The slits between trimmed pieces of one street, paved by
    /// `RoadSurfaceGapBridger`. Their quads are already in
    /// `surfaceAreas` (so the ribbons are clipped out of the slits);
    /// this list is what the surface reader draws, each quad with the
    /// style of the surface piece it touches.
    let surfaceBridges: [RoadSurfaceGapBridger.Bridge]

    static let empty = RoadLayerPrecomputation(sharedPointCounts: [:],
                                               paintLinesByFeatureIndex: [],
                                               linesByFeatureIndex: [],
                                               surfaceAreas: [],
                                               surfaceBridges: [])

    static func build(geometry: TileLayerGeometry,
                      featureFacts: [ImmersiveMapFeatureFacts],
                      featureStyles: [FeatureStyle],
                      lineClipper: LineClipper,
                      tile: Tile) -> RoadLayerPrecomputation {
        let layer = geometry.layer
        let tileExtent = Float(TileCoordinateSpace.tileExtentDouble)
        var rawLinesByFeatureIndex = Array(repeating: [[SIMD2<Float>]](), count: layer.features.count)
        var surfaceAreas: [RoadSurfaceArea] = []
        // Every feature as a road, nil for one that draws as none (hidden,
        // a fill, a label): those take no part in the road work.
        let roadStyles = featureStyles.map(\.roadStyle)

        // One payload mapping for the whole pre-pass instead of one per
        // feature geometry.
        geometry.data.withUnsafeBytes { bytes in
            for (featureIndex, feature) in layer.features.enumerated() {
                guard let style = roadStyles[featureIndex] else {
                    continue
                }
                let road = featureFacts[featureIndex].road ?? .ground
                switch feature.type {
                case .linestring:
                    let lines = geometry.lines(of: feature, in: bytes)
                    rawLinesByFeatureIndex[featureIndex] = lines.map(floatPoints)
                case .polygon where road.isSurface:
                    let polygons = geometry.polygons(of: feature, in: bytes)
                    for polygon in polygons where polygon.exteriorRing.count >= 3 {
                        // Raw tile space, y down, exactly like the road lines
                        // the clipper cuts against: the flip to render space
                        // happens later, inside the tessellators. A flipped
                        // ring here made the clipper cut every road against a
                        // MIRROR IMAGE of the area: ribbons and markings
                        // survived inside real junction areas (a pile of lane
                        // lines across every crossing), and roads at the
                        // mirrored spot were phantom-clipped. The symmetric
                        // fixture of the original test mirrored onto itself,
                        // which is how this shipped.
                        let ring = polygon.exteriorRing.map {
                            SIMD2<Float>(Float($0.x), Float($0.y))
                        }
                        var lower = ring[0]
                        var upper = ring[0]
                        for point in ring {
                            lower = simd_min(lower, point)
                            upper = simd_max(upper, point)
                        }
                        surfaceAreas.append(RoadSurfaceArea(exterior: ring,
                                                            classPriority: style.classPriority,
                                                            bounds: (lower, upper),
                                                            structureKind: RoadStructureKind(level: style.level),
                                                            layer: road.layer,
                                                            cutsShippedPaint: style.surfacePaint == .cutsAll,
                                                            cutsPaint: style.surfacePaint != .keeps,
                                                            street: road.streetIdentity,
                                                            featureIndex: featureIndex))
                    }
                default:
                    break
                }
            }
        }

        // The slits between trimmed pieces of one street are paved BEFORE
        // anything is clipped: each paving quad joins the surface set, so
        // the street's fallback ribbon is clipped out of the very slit it
        // used to poke through.
        var surfaceBridges: [RoadSurfaceGapBridger.Bridge] = []
        if surfaceAreas.contains(where: \.cutsPaint) {
            surfaceBridges = RoadSurfaceGapBridger.findBridges(
                surfaceAreas: surfaceAreas,
                linesByFeatureIndex: rawLinesByFeatureIndex,
                featureFacts: featureFacts,
                featureStyles: featureStyles,
                unitsPerMetre: ParkingBayGeometryBuilder.tileUnitsPerMetre(tile: tile)
            )
            for bridge in surfaceBridges {
                let owner = surfaceAreas[bridge.ownerAreaIndex]
                var lower = bridge.ring[0]
                var upper = bridge.ring[0]
                for point in bridge.ring {
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                }
                surfaceAreas.append(RoadSurfaceArea(exterior: bridge.ring,
                                                    classPriority: owner.classPriority,
                                                    bounds: (lower, upper),
                                                    structureKind: owner.structureKind,
                                                    layer: owner.layer,
                                                    cutsShippedPaint: owner.cutsShippedPaint,
                                                    cutsPaint: owner.cutsPaint,
                                                    street: owner.street))
            }
        }

        // A ribbon that runs inside a carriageway surface of its own or a
        // higher class is redundant there: the surface is that ground, drawn
        // as one polygon with one kerb. Left in place, the ribbon's fill paints
        // over the surface's kerb along the side it follows (a kerb on one
        // side of the street and none on the other), and its own kerbs draw
        // inside the surface. The parts inside are clipped away; the parts
        // outside keep drawing and end flush at the surface's edge.
        var paintRawLinesByFeatureIndex = rawLinesByFeatureIndex
        if surfaceAreas.isEmpty == false {
            let paintCuttingSurfaces = surfaceAreas.filter(\.cutsShippedPaint)
            for featureIndex in 0..<rawLinesByFeatureIndex.count where rawLinesByFeatureIndex[featureIndex].isEmpty == false {
                // Shipped paint already ends exactly where it ends on the
                // ground: a stop line or a crossing lies INSIDE the surface
                // polygons on purpose, and clipping it against them would
                // delete it. The one exception is a surface whose style cuts
                // all paint (a tunnel's roof: the source measures the paint
                // of the road down there like any other, but from above
                // there is only the roof to see), where the paint inside
                // goes.
                let road = featureFacts[featureIndex].road ?? .ground
                guard road.isShippedPaint == false else {
                    guard paintCuttingSurfaces.isEmpty == false else { continue }
                    rawLinesByFeatureIndex[featureIndex] = rawLinesByFeatureIndex[featureIndex].flatMap {
                        RoadSurfaceClipper.clip(polyline: $0, outside: paintCuttingSurfaces)
                    }
                    paintRawLinesByFeatureIndex[featureIndex] = rawLinesByFeatureIndex[featureIndex]
                    continue
                }
                let priority = roadStyles[featureIndex]?.classPriority ?? 0
                let structure = RoadStructureKind(level: roadStyles[featureIndex]?.level ?? .ground)
                let layerValue = road.layer
                let owners = surfaceAreas.filter {
                    $0.classPriority >= priority
                        && $0.structureKind == structure
                        && $0.layer == layerValue
                }
                guard owners.isEmpty == false else { continue }
                rawLinesByFeatureIndex[featureIndex] = rawLinesByFeatureIndex[featureIndex].flatMap {
                    RoadSurfaceClipper.clip(polyline: $0, outside: owners)
                }
                // The paint's track is cut only by the crossings: a street
                // inside a hand-mapped carriageway area keeps its markings.
                let paintOwners = owners.filter(\.cutsPaint)
                if paintOwners.isEmpty == false {
                    paintRawLinesByFeatureIndex[featureIndex] = paintRawLinesByFeatureIndex[featureIndex].flatMap {
                        RoadSurfaceClipper.clip(polyline: $0, outside: paintOwners)
                    }
                }
            }
        }

        // Pieces of one street that the tiles ship cut (OSM way boundaries a
        // merge did not close, or cuts the tiler made) are stitched end to
        // end before tessellation, so the street is one ribbon with no seam
        // where the pieces met: no pair of caps, no kerb across the join.
        // Stitching needs a street identity on the geometry (`name`, with the
        // drawing attributes equal); without it nothing is stitched and the
        // pieces draw as they arrive.
        let stitched = RoadStreetStitcher.stitch(linesByFeatureIndex: rawLinesByFeatureIndex,
                                                 featureFacts: featureFacts,
                                                 featureStyles: featureStyles)
        let paintStitched = RoadStreetStitcher.stitch(linesByFeatureIndex: paintRawLinesByFeatureIndex,
                                                      featureFacts: featureFacts,
                                                      featureStyles: featureStyles)
        var paintLinesByFeatureIndex = Array(repeating: [PreparedRoadLine](), count: layer.features.count)
        for (featureIndex, lines) in paintStitched.enumerated() where lines.isEmpty == false {
            var prepared: [PreparedRoadLine] = []
            prepared.reserveCapacity(lines.count)
            for points in lines {
                prepared.append(PreparedRoadLine(points: points,
                                                 exactFragments: lineClipper.clip(points: points,
                                                                                  tileExtent: tileExtent)))
            }
            paintLinesByFeatureIndex[featureIndex] = prepared
        }

        var pointCounts: [RoadConnectionPointKey: Int] = [:]
        var linesByFeatureIndex = Array(repeating: [PreparedRoadLine](), count: layer.features.count)
        for (featureIndex, lines) in stitched.enumerated() where lines.isEmpty == false {
            var preparedLines: [PreparedRoadLine] = []
            preparedLines.reserveCapacity(lines.count)
            // Shipped paint is not a street: its endpoints lie on the roads
            // it is painted on, and letting them count would fabricate a
            // connection at every point a marking happens to share with a
            // road vertex.
            let isShippedPaint = featureFacts[featureIndex].road?.isShippedPaint == true
            for points in lines {
                let fragments = lineClipper.clip(points: points, tileExtent: tileExtent)
                for fragment in fragments {
                    for point in fragment.points {
                        guard isShippedPaint == false else { break }
                        pointCounts[RoadConnectionPointKey(point: point), default: 0] += 1
                    }
                }
                preparedLines.append(PreparedRoadLine(points: points, exactFragments: fragments))
            }
            linesByFeatureIndex[featureIndex] = preparedLines
        }

        return RoadLayerPrecomputation(sharedPointCounts: pointCounts,
                                       paintLinesByFeatureIndex: paintLinesByFeatureIndex,
                                       linesByFeatureIndex: linesByFeatureIndex,
                                       surfaceAreas: surfaceAreas,
                                       surfaceBridges: surfaceBridges)
    }

    static func floatPoints(_ line: LineString) -> [SIMD2<Float>] {
        line.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
    }
}

/// What the readers know about the layer a feature comes from, decided once
/// per layer: whether it takes the separate-road path, and the pre-pass.
struct RoadLayerContext {
    /// The separate-road path: seamless ribbons with the casing under the
    /// fill, sorted by structure and class. Only the road layer, from the
    /// zoom the options name; every other line draws as ground geometry.
    let usesSeparateRoadRendering: Bool
    let precomputation: RoadLayerPrecomputation
}
