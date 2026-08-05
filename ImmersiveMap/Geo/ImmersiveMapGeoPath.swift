// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A trajectory over the globe: waypoints joined by great-circle arcs, plus an
/// altitude profile above the map surface.
///
/// The same value describes the drawn route (``ImmersiveMapRoute``) and the
/// trajectory a 3D model flies along
/// (`ImmersiveMapSceneModelsController.animate(id:along:duration:)`), so the
/// model is guaranteed to ride exactly on the line that is drawn.
///
/// The path is parameterized by `fraction` in `0...1`, measured along arc
/// length: `0` is the first waypoint, `1` is the last one, and a waypoint in
/// the middle sits at its share of the total arc.
public struct ImmersiveMapGeoPath: Equatable, Hashable, Sendable {
    /// Two or more coordinates. Fewer, or a path whose points all coincide,
    /// draws nothing and animates nothing.
    public var waypoints: [GeoCoordinate]
    /// Altitude held over the whole path, in meters above the map surface.
    public var baseAltitudeMeters: Double
    /// Additional altitude at the middle of the path, in meters. The profile is
    /// `base + peak * sin(pi * fraction)`: it starts and ends at `base` and
    /// crests at `base + peak`, which is what makes a flight path arc away from
    /// the globe and back.
    public var peakAltitudeMeters: Double

    public init(waypoints: [GeoCoordinate],
                baseAltitudeMeters: Double = 0,
                peakAltitudeMeters: Double = 0) {
        self.waypoints = waypoints
        self.baseAltitudeMeters = baseAltitudeMeters
        self.peakAltitudeMeters = peakAltitudeMeters
    }

    public init(from start: GeoCoordinate,
                to end: GeoCoordinate,
                baseAltitudeMeters: Double = 0,
                peakAltitudeMeters: Double = 0) {
        self.init(waypoints: [start, end],
                  baseAltitudeMeters: baseAltitudeMeters,
                  peakAltitudeMeters: peakAltitudeMeters)
    }

    /// Altitude of the profile at `fraction`, in meters.
    public func altitudeMeters(atFraction fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        guard peakAltitudeMeters != 0 else { return baseAltitudeMeters }
        return baseAltitudeMeters + peakAltitudeMeters * sin(.pi * clamped)
    }
}
