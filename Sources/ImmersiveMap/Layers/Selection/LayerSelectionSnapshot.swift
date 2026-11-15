// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import simd

/// The shape of a layer a tap landed on.
struct LayerSelectionHit: Equatable {
    let layerID: String
    let shapeID: UInt64
    /// The place on the map under the tap.
    let coordinate: GeoCoordinate
}

/// Hit-test state of one rendered frame: the layers it drew, in the order
/// it drew them, each with the shapes of its source, and the projection it
/// drew them with. What is on screen is what can be tapped: a hidden layer,
/// one outside its zooms and one whose source is not read are not here.
struct LayerSelectionSnapshot: SelectionPickData, @unchecked Sendable {
    /// A line thinner than this is hard to aim at: its hit area grows to
    /// this half width, in points.
    static let minimumLineReachPoints: Double = 8
    /// A point smaller than this grows to this radius, in points.
    static let minimumPointReachPoints: Double = 16

    struct Entry {
        let layer: ImmersiveMapLayer
        let content: LayerSourceContent
    }

    static let empty = LayerSelectionSnapshot(frameIndex: 0, drawSize: .zero, projection: nil, entries: [])

    var kind: ImmersiveMapSelection.Kind { .layers }
    let frameIndex: UInt64
    let drawSize: CGSize
    /// The frame's projection, nil for a frame that drew no layer.
    let projection: GeoScreenProjectionMath.FrameConstants?
    let entries: [Entry]

    /// The shape under `point` (drawable pixels, origin bottom-left): of
    /// the layer drawn last first, and within a layer its points, then its
    /// lines, then its zones, as they cover each other on screen.
    func hitTest(point: CGPoint, pixelsPerPoint: CGFloat) -> LayerSelectionHit? {
        guard entries.isEmpty == false, let projection else { return nil }
        let pixel = SIMD2<Double>(Double(point.x), Double(point.y))
        guard let place = LayerPickMath.place(under: pixel,
                                              start: Self.centre(of: projection),
                                              project: { Self.project($0, projection) }) else {
            return nil
        }
        return Self.hit(in: entries, at: place, pixelsPerPoint: Double(pixelsPerPoint))
    }

    /// The shape of `entries` at a place on the map, the entry drawn last
    /// first.
    static func hit(in entries: [Entry], at place: LayerPickMath.Place, pixelsPerPoint: Double) -> LayerSelectionHit? {
        let coordinate = LayerPickMath.coordinate(ofWorld: place.world)
        for entry in entries.reversed() {
            if let shapeID = hitTest(entry, place: place, coordinate: coordinate, pixelsPerPoint: pixelsPerPoint) {
                return LayerSelectionHit(layerID: entry.layer.id, shapeID: shapeID, coordinate: coordinate)
            }
        }
        return nil
    }

    // MARK: - The projection

    /// The world position the camera looks at, where the search for a
    /// tap's place starts.
    private static func centre(of projection: GeoScreenProjectionMath.FrameConstants) -> SIMD2<Double> {
        switch projection.mode {
        case .flat:
            return ImmersiveMapProjection.centerWorldMercator(fromFlatPan: projection.flatPan)
        case .globe:
            return ImmersiveMapProjection.centerWorldMercator(fromGlobePan: SIMD2(Double(projection.globe.panX),
                                                                                  Double(projection.globe.panY)))
        }
    }

    private static func project(_ world: SIMD2<Double>,
                                _ projection: GeoScreenProjectionMath.FrameConstants) -> SIMD2<Double>? {
        let coordinate = LayerPickMath.coordinate(ofWorld: world)
        let output = GeoScreenProjectionMath.project(basis: GeoProjectionBasis(coordinate: coordinate),
                                                     constants: projection)
        guard output.visible != 0, output.visibilityAlpha > 0,
              output.position.x.isFinite, output.position.y.isFinite else {
            return nil
        }
        return SIMD2(Double(output.position.x), Double(output.position.y))
    }

    // MARK: - One layer

    private static func hitTest(_ entry: Entry,
                                place: LayerPickMath.Place,
                                coordinate: GeoCoordinate,
                                pixelsPerPoint: Double) -> UInt64? {
        let layer = entry.layer
        let content = entry.content

        // The nearest point whose disc, or its touch target, holds the tap.
        var nearest: (id: UInt64, distance: Double)?
        for point in content.points {
            let style = layer.style(of: point)
            guard style.radiusPoints + style.strokeWidthPoints > 0,
                  style.color.w > 0 || style.strokeColor.w > 0 else { continue }
            let reach = max(Double(style.radiusPoints + style.strokeWidthPoints), minimumPointReachPoints) * pixelsPerPoint
            let margin = place.worldReach(ofPixels: reach) * 360
            guard LayerPickMath.box(of: [point.coordinate], holds: coordinate, margin: margin) else { continue }
            let distance = simd_length(place.pixelOffset(to: near(LayerMeshBuilder.world(point.coordinate), place)))
            if distance <= reach, distance < (nearest?.distance ?? .infinity), let id = point.id {
                nearest = (id, distance)
            }
        }
        if let nearest { return nearest.id }

        // The nearest line within its half width, or its touch target.
        for polyline in content.polylines {
            let style = layer.style(of: polyline)
            guard style.color.w > 0, style.widthPoints > 0 else { continue }
            let reach = max(Double(style.widthPoints) / 2, minimumLineReachPoints) * pixelsPerPoint
            guard let distance = distance(toLine: polyline.coordinates, closed: false, reach: reach,
                                          place: place, coordinate: coordinate) else { continue }
            if distance < (nearest?.distance ?? .infinity), let id = polyline.id {
                nearest = (id, distance)
            }
        }
        if let nearest { return nearest.id }

        // The zone drawn last that holds the tap in its fill, or has its
        // outline under it when it has no fill.
        for polygon in content.polygons.reversed() {
            guard let id = polygon.id else { continue }
            let style = layer.style(of: polygon)
            if style.fillColor.w > 0 {
                guard LayerPickMath.box(of: polygon.exterior, holds: coordinate, margin: 0) else { continue }
                let exterior = ring(polygon.exterior, near: place)
                guard exterior.count >= 3, LayerPickMath.ring(exterior, contains: place.world) else { continue }
                let inHole = polygon.holes.contains { hole in
                    let ring = ring(hole, near: place)
                    return ring.count >= 3 && LayerPickMath.ring(ring, contains: place.world)
                }
                if inHole == false { return id }
            } else if style.strokeColor.w > 0, style.strokeWidthPoints > 0 {
                let reach = max(Double(style.strokeWidthPoints) / 2, minimumLineReachPoints) * pixelsPerPoint
                for ring in [polygon.exterior] + polygon.holes
                where distance(toLine: ring, closed: true, reach: reach, place: place, coordinate: coordinate) != nil {
                    return id
                }
            }
        }
        return nil
    }

    /// How far the tap is from a line on screen, nil when farther than
    /// `reach` pixels.
    private static func distance(toLine coordinates: [GeoCoordinate],
                                 closed: Bool,
                                 reach: Double,
                                 place: LayerPickMath.Place,
                                 coordinate: GeoCoordinate) -> Double? {
        let margin = place.worldReach(ofPixels: reach) * 360
        guard LayerPickMath.box(of: coordinates, holds: coordinate, margin: margin) else { return nil }
        let offsets = ring(coordinates, near: place).map { place.pixelOffset(to: $0) }
        guard let first = offsets.first else { return nil }
        var nearest = simd_length(first)
        var previous = first
        for offset in offsets.dropFirst() + (closed ? [first] : []) {
            nearest = min(nearest, LayerPickMath.distanceFromOrigin(toSegment: previous, offset))
            previous = offset
        }
        return nearest <= reach ? nearest : nil
    }

    /// A ring or a line in the world as the layer draws it
    /// (`LayerMeshBuilder.unwrappedWorld`), in the copy of the world the
    /// tap's place lies in.
    private static func ring(_ coordinates: [GeoCoordinate], near place: LayerPickMath.Place) -> [SIMD2<Double>] {
        let world = LayerMeshBuilder.unwrappedWorld(coordinates, reference: nil)
        guard let minimum = world.map(\.x).min(), let maximum = world.map(\.x).max() else { return [] }
        let shift = (place.world.x - (minimum + maximum) / 2).rounded()
        return shift == 0 ? world : world.map { $0 + SIMD2(shift, 0) }
    }

    private static func near(_ world: SIMD2<Double>, _ place: LayerPickMath.Place) -> SIMD2<Double> {
        world + SIMD2((place.world.x - world.x).rounded(), 0)
    }
}
