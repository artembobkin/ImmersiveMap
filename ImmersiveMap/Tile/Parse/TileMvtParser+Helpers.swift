// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt
import simd

extension TileMvtParser {
    /// The tag pairs of a feature as a dictionary; the loop itself is
    /// `MvtAttributeDecoder`, in the decoder's module next to its reader.
    func decodeAttributes(feature: MvtDecodedFeature,
                          layer: MvtDecodedLayer,
                          data: Data) -> [String: MvtValue] {
        MvtAttributeDecoder.attributes(of: feature, in: layer, data: data)
    }

    func decodeAttributes(feature: MvtDecodedFeature,
                          layer: MvtDecodedLayer,
                          bytes: UnsafeRawBufferPointer) -> [String: MvtValue] {
        MvtAttributeDecoder.attributes(of: feature, in: layer, bytes: bytes)
    }

    /// Puts a carriageway-surface polygon (a junction area) into the road
    /// phases: the triangulated polygon under the style's fill pass, and each
    /// ring, closed, tessellated as a kerb under the casing pass. Both carry
    /// the style's class priority so they sort among the roads of that class:
    /// the surface is drawn after the ribbons' casings of its class and under
    /// their fills, exactly where a ribbon's own fill would go, so the ribbons
    /// entering the junction merge into it and their kerbs stop at its edge.
    /// `clippedExterior`/`clippedInteriors` and `surfaceAreas` are all TILE
    /// space (y down); only `parsedGeometry.parsedPolygon` (the fill) is
    /// already tessellated render-space vertices.
    func appendRoadSurfaceArea(parsedGeometry: ParsePolygon.ParsedGeometry,
                               clippedExterior: [SIMD2<Float>],
                               clippedInteriors: [[SIMD2<Float>]],
                               style: FeatureStyle,
                               attributes: [String: MvtValue],
                               tile: Tile,
                               surfaceAreas: [TileMvtParser.RoadSurfaceArea],
                               into result: inout ReadingStageResult,
                               parseLine: ParseLine) {
        let structure: RoadStructureKind = roadStructureKind(attributes: attributes) == .ground
            ? .automobileGround
            : roadStructureKind(attributes: attributes)
        let layer = roadLayerValue(attributes: attributes)
        for pass in style.resolvedLineRenderPasses {
            let passStyle = FeatureStyle(
                key: pass.key,
                color: pass.color,
                streetColor: pass.streetColor,
                lowZoomFadeMask: pass.lowZoomFadeMask,
                parseGeometryStyleData: pass.parseGeometryStyleData,
                roadClassPriority: style.roadClassPriority
            )
            result.registerRoadStyle(passStyle, key: pass.key)
            var polygons: [ParsedPolygon] = []
            switch pass.roadPassRole {
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
                    if let kerb = parseLine.parse(points: closed,
                                                  width: pass.parseGeometryStyleData.lineWidth,
                                                  tileExtent: Float(tileExtent),
                                                  startCapRound: false,
                                                  endCapRound: false,
                                                  lineJoinRound: true,
                                                  clipGeometryToTileBounds: true) {
                        polygons.append(kerb)
                    }
                }
            case .detail where style.roadDecorationKind == .parkingBays:
                // The parking-bay comb: short stripes laid out by the
                // builder in tile space (the ring already is), each
                // tessellated as its own point-locked stroke with hard ends.
                let unitsPerMetre = ParkingBayGeometryBuilder.tileUnitsPerMetre(tile: tile)
                var stripes = parkingBayBuilder.buildStripes(
                    exterior: clippedExterior,
                    unitsPerMetre: unitsPerMetre,
                    orientation: attributes["orientation"]?.stringValue
                )
                // Where a carriageway, a junction or a bus lane overlaps the
                // lot, that ground is theirs: the comb ends at their edge
                // instead of climbing onto the roadway.
                let owners = surfaceAreas.filter {
                    $0.classPriority > style.roadClassPriority
                        && $0.structureKind == roadStructureKind(attributes: attributes)
                }
                if owners.isEmpty == false {
                    stripes = stripes.flatMap { RoadSurfaceClipper.clip(polyline: $0, outside: owners) }
                        .filter { stripe in
                            guard let first = stripe.first, let last = stripe.last else { return false }
                            return simd_distance(first, last) >= ParkingBayGeometryBuilder.minimumStripeMetres * unitsPerMetre
                        }
                }
                for stripe in stripes {
                    if let stroke = parseLine.parse(points: stripe,
                                                    width: pass.parseGeometryStyleData.lineWidth,
                                                    tileExtent: Float(tileExtent),
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
                                  classPriority: style.roadClassPriority,
                                  passRole: pass.roadPassRole)
            }
        }
    }
}
