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
    /// Set on the PAINT track only: this end of the line was created by
    /// cutting the street against a crossing's surface. The surface is
    /// the gap, so the paint runs right up to its edge instead of also
    /// backing off by its own half-carriageway: with both, a street
    /// crossed by a chain of small junctions lost its markings entirely,
    /// each short piece eaten by two ten-metre insets.
    var paintCutAtStart: Bool = false
    var paintCutAtEnd: Bool = false
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
    /// Whether the surface draws the tunnel look: tagged as a tunnel, or
    /// found to be a tunnel's roof by `RoadTunnelSurfaceResolver`. A tunnel
    /// surface is a bare translucent fill: every line of shipped paint
    /// inside it is clipped away, unlike on any other surface.
    var isTunnel: Bool = false
    /// See `FeatureStyle.surfaceAreaCutsPaint`: true for a reconstructed
    /// crossing, false for a hand-mapped carriageway area.
    var cutsPaint: Bool = false
    /// The street identity of the piece as the style read it, empty when
    /// the source ships none. Only the gap bridger reads it: a slit is
    /// paved only between two pieces of the SAME street.
    var street: String = ""
    /// The feature the surface was decoded from, -1 for a synthesized
    /// quad: the bridger's paving inherits this feature's style.
    var featureIndex: Int = -1
}

/// What the separate-road path knows about a whole road layer before any
/// of its features is read: every line clipped by the carriageway surfaces
/// and stitched into streets, the junctions counted, the slits between
/// surface pieces paved. Built once per road layer at street zooms, and
/// `empty` for every other layer.
struct RoadLayerPrecomputation {
    let sharedPointCounts: [RoadConnectionPointKey: Int]
    /// How many distinct STREETS touch each point, counted over the
    /// classes that make a junction for the paint down a carriageway:
    /// `minor` and above.
    ///
    /// A street is its name, so the two sides of a seam the stitcher
    /// could not close (a piece whose lane count or oneway differs)
    /// count once between them: the paint runs through, because on the
    /// ground the street does. A footpath crossing the line is not a
    /// junction either, and neither is a service driveway or a parking
    /// aisle meeting a street: paint does not break for a gateway.
    let automobilePointCounts: [RoadConnectionPointKey: Int]
    /// The lines a feature's PAINT is built from: the same raw lines,
    /// but clipped only by the surfaces that cut paint (junctions
    /// reconstructed from the graph), not by every surface. A hand-mapped
    /// carriageway area covers a whole street, and a street inside one
    /// keeps its markings; a crossing does not.
    let paintLinesByFeatureIndex: [[PreparedRoadLine]]
    /// Half the widest carriageway that meets each point, in tile units.
    /// The gap a marking leaves at a junction is the room the crossing
    /// road takes, not the room its own road takes: a lane line running
    /// into a six-lane avenue has to clear the avenue.
    let junctionHalfWidths: [RoadConnectionPointKey: Float]
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
                                               automobilePointCounts: [:],
                                               paintLinesByFeatureIndex: [],
                                               junctionHalfWidths: [:],
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

        // One payload mapping for the whole pre-pass instead of one per
        // feature geometry.
        geometry.data.withUnsafeBytes { bytes in
            for (featureIndex, feature) in layer.features.enumerated() {
                let style = featureStyles[featureIndex]
                let road = featureFacts[featureIndex].road ?? .ground
                guard style.key != 0 else {
                    continue
                }
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
                                                            classPriority: style.roadClassPriority,
                                                            bounds: (lower, upper),
                                                            structureKind: RoadStructureKind(road: road),
                                                            layer: road.layer,
                                                            isTunnel: road.isTunnel,
                                                            cutsPaint: style.surfaceAreaCutsPaint,
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
                                                    isTunnel: owner.isTunnel,
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
            let tunnelSurfaces = surfaceAreas.filter(\.isTunnel)
            for featureIndex in 0..<rawLinesByFeatureIndex.count where rawLinesByFeatureIndex[featureIndex].isEmpty == false {
                // Shipped paint already ends exactly where it ends on the
                // ground: a stop line or a crossing lies INSIDE the surface
                // polygons on purpose, and clipping it against them would
                // delete it. The one exception is a tunnel: the source
                // measures the paint of the road down there like any other,
                // but from above there is only the tunnel's roof to see, a
                // bare translucent fill, so the paint inside it goes.
                let road = featureFacts[featureIndex].road ?? .ground
                guard road.isShippedPaint == false else {
                    guard tunnelSurfaces.isEmpty == false else { continue }
                    rawLinesByFeatureIndex[featureIndex] = rawLinesByFeatureIndex[featureIndex].flatMap {
                        RoadSurfaceClipper.clip(polyline: $0, outside: tunnelSurfaces)
                    }
                    paintRawLinesByFeatureIndex[featureIndex] = rawLinesByFeatureIndex[featureIndex]
                    continue
                }
                let priority = featureStyles[featureIndex].roadClassPriority
                let structure = RoadStructureKind(road: road)
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
        // An endpoint that lies on a crossing's outline is a cut the clipper
        // made, not an end of the street: recognised geometrically after the
        // stitcher has run, because stitching rearranges which piece carries
        // which end.
        let paintCutRings = surfaceAreas.filter(\.cutsPaint).map(\.exterior)
        func liesOnACrossingOutline(_ point: SIMD2<Float>) -> Bool {
            for ring in paintCutRings {
                for index in 0..<ring.count {
                    let a = ring[index]
                    let b = ring[(index + 1) % ring.count]
                    let ab = b - a
                    let lengthSquared = simd_length_squared(ab)
                    guard lengthSquared > 0 else { continue }
                    let t = simd_clamp(simd_dot(point - a, ab) / lengthSquared, 0, 1)
                    if simd_distance_squared(point, a + ab * t) < 0.25 {
                        return true
                    }
                }
            }
            return false
        }
        var paintLinesByFeatureIndex = Array(repeating: [PreparedRoadLine](), count: layer.features.count)
        for (featureIndex, lines) in paintStitched.enumerated() where lines.isEmpty == false {
            var prepared: [PreparedRoadLine] = []
            prepared.reserveCapacity(lines.count)
            for points in lines {
                prepared.append(PreparedRoadLine(points: points,
                                                 exactFragments: lineClipper.clip(points: points,
                                                                                  tileExtent: tileExtent),
                                                 paintCutAtStart: points.first.map(liesOnACrossingOutline) ?? false,
                                                 paintCutAtEnd: points.last.map(liesOnACrossingOutline) ?? false))
            }
            paintLinesByFeatureIndex[featureIndex] = prepared
        }

        var pointCounts: [RoadConnectionPointKey: Int] = [:]
        // Distinct streets per point, not occurrences and not features: a
        // street arrives cut into pieces the stitcher could not join, and
        // both sides of such a seam carry the same point. Counting it twice
        // there calls the seam a junction and breaks the paint on a street
        // that simply continues.
        //
        // Which street a piece belongs to is the source's answer where it
        // gives one (the street identity, an id assembled from the whole
        // network before the tiles were cut, so it holds across a tile
        // boundary and tells two same-named streets in different towns
        // apart). A source without one falls back to the name, which is
        // right within a tile and wrong only where two unrelated streets
        // share one; a piece with neither answers only for itself.
        var streetIdentifiers: [String: Int] = [:]
        var streetIdentifierByFeature = [Int](repeating: -1, count: layer.features.count)
        for index in 0..<layer.features.count {
            let road = featureFacts[index].road ?? .ground
            let identity = road.streetIdentity.isEmpty == false
                ? "street=" + road.streetIdentity
                : road.name.isEmpty == false ? "name=" + road.name : ""
            if identity.isEmpty {
                streetIdentifierByFeature[index] = Int.min + index
            } else {
                let next = streetIdentifiers.count
                streetIdentifierByFeature[index] = streetIdentifiers[identity] ?? next
                if streetIdentifiers[identity] == nil { streetIdentifiers[identity] = next }
            }
        }
        var automobileStreetsAtPoint: [RoadConnectionPointKey: Set<Int>] = [:]
        var junctionHalfWidths: [RoadConnectionPointKey: Float] = [:]
        var linesByFeatureIndex = Array(repeating: [PreparedRoadLine](), count: layer.features.count)
        for (featureIndex, lines) in stitched.enumerated() where lines.isEmpty == false {
            var preparedLines: [PreparedRoadLine] = []
            preparedLines.reserveCapacity(lines.count)
            // Shipped paint is not a street: its endpoints lie on the roads
            // it is painted on, and letting them count would fabricate a
            // junction (or a connection) at every point a marking happens to
            // share with a road vertex. Which roads make a junction for the
            // paint on another is the style's decision.
            let isShippedPaint = featureFacts[featureIndex].road?.isShippedPaint == true
            let isJunctionMaking = featureStyles[featureIndex].roadMakesJunctions
            // The carriageway this feature draws at: the style's own geometry
            // is the fill ribbon, so half of it is how far the road reaches
            // from its centreline.
            let halfWidth = Float(featureStyles[featureIndex].lineGeometry.lineWidth) * 0.5
            for points in lines {
                let fragments = lineClipper.clip(points: points, tileExtent: tileExtent)
                for fragment in fragments {
                    for point in fragment.points {
                        guard isShippedPaint == false else { break }
                        let key = RoadConnectionPointKey(point: point)
                        pointCounts[key, default: 0] += 1
                        if isJunctionMaking {
                            automobileStreetsAtPoint[key, default: []].insert(streetIdentifierByFeature[featureIndex])
                            junctionHalfWidths[key] = max(junctionHalfWidths[key] ?? 0, halfWidth)
                        }
                    }
                }
                preparedLines.append(PreparedRoadLine(points: points, exactFragments: fragments))
            }
            linesByFeatureIndex[featureIndex] = preparedLines
        }
        let automobilePointCounts = automobileStreetsAtPoint.mapValues(\.count)

        return RoadLayerPrecomputation(sharedPointCounts: pointCounts,
                                       automobilePointCounts: automobilePointCounts,
                                       paintLinesByFeatureIndex: paintLinesByFeatureIndex,
                                       junctionHalfWidths: junctionHalfWidths,
                                       linesByFeatureIndex: linesByFeatureIndex,
                                       surfaceAreas: surfaceAreas,
                                       surfaceBridges: surfaceBridges)
    }

    static func floatPoints(_ line: LineString) -> [SIMD2<Float>] {
        line.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
    }
}

/// What the readers know about the layer a feature comes from, decided once
/// per layer: whether it takes the separate-road path, whether its
/// measured crossings supersede the attribute-tagged ones, and the pre-pass.
struct RoadLayerContext {
    /// The separate-road path: seamless ribbons with the casing under the
    /// fill, sorted by structure and class. Only the road layer, from the
    /// zoom the options name; every other line draws as ground geometry.
    let usesSeparateRoadRendering: Bool
    /// Where the tiles ship measured crossing lines, the attribute
    /// tagged crossings of the same layer are the same crossings seen
    /// through OSM tags: drawing both stripes the junction twice. The
    /// measured line wins.
    let hasShippedCrossings: Bool
    let precomputation: RoadLayerPrecomputation
}
