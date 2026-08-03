// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A 3D model (USDZ or OBJ, loaded via Model I/O) anchored at a geographic
/// coordinate. Rendered inside the map world pass in flat, globe, and the
/// morph between them. Sized in real-world meters with the Web-Mercator
/// convention: together with the surrounding map geometry the model inflates
/// by 1/cos(latitude) toward the poles.
public struct ImmersiveMapSceneModel: Identifiable, Equatable, Sendable {
    /// Location of a model asset. Only local file URLs are supported (bundle
    /// resources or previously downloaded files); the engine performs no
    /// networking. Models sharing a source share one loaded mesh.
    public struct Source: Hashable, Sendable {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        /// Resolves a bundle resource (for example `("biplane", "usdz")`) to
        /// its file URL; nil when the resource is missing.
        public init?(resource name: String, withExtension ext: String, in bundle: Bundle = .main) {
            guard let url = bundle.url(forResource: name, withExtension: ext) else {
                return nil
            }
            self.url = url
        }
    }

    public var id: UInt64
    public var source: Source
    public var coordinate: GeoCoordinate
    /// Offset above the map surface along the local up vector, in meters.
    public var altitudeMeters: Double
    /// Rotation about the local up axis, clockwise from north, in degrees.
    public var headingDegrees: Double
    /// Rotation about the local east axis, in degrees.
    public var pitchDegrees: Double
    /// Rotation about the model's forward axis, in degrees.
    public var rollDegrees: Double
    /// Multiplier over real-world meters. Model I/O does not expose the USD
    /// stage `metersPerUnit`, so one asset unit is presented as one meter.
    public var scale: Double
    /// When set, the asset is uniformly rescaled so the largest extent of its
    /// bounding box spans this many meters (applied before `scale`).
    public var fitDiameterMeters: Double?

    public init(id: UInt64,
                source: Source,
                coordinate: GeoCoordinate,
                altitudeMeters: Double = 0,
                headingDegrees: Double = 0,
                pitchDegrees: Double = 0,
                rollDegrees: Double = 0,
                scale: Double = 1,
                fitDiameterMeters: Double? = nil) {
        self.id = id
        self.source = source
        self.coordinate = coordinate
        self.altitudeMeters = altitudeMeters
        self.headingDegrees = headingDegrees
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
        self.scale = scale
        self.fitDiameterMeters = fitDiameterMeters
    }
}
