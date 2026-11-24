// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// A box of latitude and longitude, in degrees, by its south-west and its
/// north-east corners. A north-east longitude west of the south-west one
/// spans the antimeridian: from 170 to -170 is the 20 degrees across the
/// 180th meridian, not the 340 the other way round.
public struct ImmersiveMapGeoBounds: Hashable, Codable, Sendable {
    public var southWest: GeoCoordinate
    public var northEast: GeoCoordinate

    public init(southWest: GeoCoordinate, northEast: GeoCoordinate) {
        self.southWest = southWest
        self.northEast = northEast
    }

    /// Whether the box holds the coordinate, its edges included.
    public func contains(_ coordinate: GeoCoordinate) -> Bool {
        guard coordinate.latitude >= southWest.latitude, coordinate.latitude <= northEast.latitude else {
            return false
        }
        let longitude = Self.wrapped(coordinate.longitude)
        return longitudeSpans.contains { longitude >= $0.lowerBound && longitude <= $0.upperBound }
    }

    /// Whether the two boxes have a point in common, their edges included.
    public func intersects(_ other: ImmersiveMapGeoBounds) -> Bool {
        guard southWest.latitude <= other.northEast.latitude, other.southWest.latitude <= northEast.latitude else {
            return false
        }
        let others = other.longitudeSpans
        return longitudeSpans.contains { span in others.contains { span.overlaps($0) } }
    }

    /// Whether the two boxes share an area, more than an edge or a corner:
    /// a tile beside a box drawn along its edge does not overlap it.
    func overlaps(_ other: ImmersiveMapGeoBounds) -> Bool {
        guard southWest.latitude < other.northEast.latitude, other.southWest.latitude < northEast.latitude else {
            return false
        }
        let others = other.longitudeSpans
        return longitudeSpans.contains { span in
            others.contains { span.lowerBound < $0.upperBound && $0.lowerBound < span.upperBound }
        }
    }

    /// The longitudes of the box within -180...180: one span, or two for a
    /// box across the antimeridian.
    private var longitudeSpans: [ClosedRange<Double>] {
        // A box written as the whole turn or more is the whole turn.
        if northEast.longitude - southWest.longitude >= 360 { return [-180 ... 180] }
        let west = Self.wrapped(southWest.longitude)
        var east = Self.wrapped(northEast.longitude)
        // An east edge on the antimeridian is written 180 and wraps to -180.
        if east == -180, northEast.longitude > southWest.longitude { east = 180 }
        if west <= east { return [west ... east] }
        return [west ... 180, -180 ... east]
    }

    /// A longitude within -180..<180.
    private static func wrapped(_ longitude: Double) -> Double {
        if longitude >= -180, longitude < 180 { return longitude }
        if longitude == 180 { return 180 }
        let turn = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (turn < 0 ? turn + 360 : turn) - 180
    }
}
