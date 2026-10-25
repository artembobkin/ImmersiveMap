// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Reads what the country around the point the camera looks at is like
/// off the frame's relief (`ImmersiveMapTerrainSurroundings`), once a frame
/// while the frame is on the terrain. The frame's own reading, kept by the
/// engine across frames for the smoothing and the hysteresis.
///
/// The heights are read on the CPU from the camera's own terrain map
/// (`GroundReliefFrame.cameraTerrainZoom`, the map the camera flies over
/// at every zoom, bilinear and continuous in the camera's place), at the
/// centre and on two rings around it, a few dozen lookups: nothing of the
/// GPU, no readback, no latency. The sample is taken again only when the
/// point has moved a share of the radius, the terrain in has changed or
/// the radius was set, and the smoothing runs every frame from the last
/// sample.
struct GroundReliefSurroundings {
    typealias Settings = ImmersiveMapSettings.TileSettings.TerrainSurroundingsSettings

    /// Points on the outer ring, at the radius, and on the inner ring, at
    /// half of it. Enough to meet a ridge or a valley that crosses the disc
    /// whichever way it runs, cheap enough to take again on every move.
    static let outerRingCount = 16
    static let innerRingCount = 8
    /// How far the point moves, as a share of the radius, before the disc
    /// is sampled again.
    static let resampleShare = 0.02

    private var smoothedSpanMetres: Float?
    private var kind: ImmersiveMapTerrainSurroundings.Kind?
    private var sampledSpanMetres: Float?
    private var sampledCentre: SIMD2<Double>?
    private var sampledVersion: UInt64?
    private var sampledRadiusMetres: Float?

    /// The reading for this frame, nil off the terrain, and nil while the
    /// terrain under the point is still on its way the first time. Off the
    /// terrain the smoothing and the kind are dropped, so a relief that
    /// rises again starts from what it finds, not from where it left off.
    mutating func update(relief: GroundReliefFrame,
                         centerWorldMercator: SIMD2<Double>,
                         settings: Settings,
                         deltaTime: TimeInterval) -> ImmersiveMapTerrainSurroundings? {
        guard relief.isActive else {
            reset()
            return nil
        }
        sample(relief: relief, centerWorldMercator: centerWorldMercator, settings: settings)
        guard let sampledSpanMetres else {
            return nil
        }
        let smoothed: Float
        if let previous = smoothedSpanMetres {
            let share = Self.smoothingShare(deltaTime: deltaTime, halfLife: settings.smoothingHalfLife)
            smoothed = previous + (sampledSpanMetres - previous) * share
        } else {
            smoothed = sampledSpanMetres
        }
        smoothedSpanMetres = smoothed
        let kind = Self.kind(after: kind, spanMetres: smoothed, settings: settings)
        self.kind = kind
        // Rounded so a reading that moves by less than the app can see
        // compares equal to the last one and is not reported again.
        return ImmersiveMapTerrainSurroundings(kind: kind,
                                               mountainousness: (Self.mountainousness(spanMetres: smoothed, settings: settings) * 100).rounded() / 100,
                                               heightSpanMetres: smoothed.rounded(),
                                               groundMetres: relief.datumMetres.rounded())
    }

    mutating func reset() {
        smoothedSpanMetres = nil
        kind = nil
        sampledSpanMetres = nil
        sampledCentre = nil
        sampledVersion = nil
        sampledRadiusMetres = nil
    }

    /// Takes the disc's span again when the point moved a share of the
    /// radius, the terrain in changed or the radius was set. A sample that
    /// finds no terrain keeps the last one.
    private mutating func sample(relief: GroundReliefFrame, centerWorldMercator: SIMD2<Double>, settings: Settings) {
        let radiusMetres = max(settings.sampleRadiusMetres, 1)
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centerWorldMercator.y)
        let metresPerWorld = ImmersiveMapProjection.earthCircumferenceMeters * max(cos(latitude), 1e-6)
        let radiusWorld = Double(radiusMetres) / metresPerWorld
        if let sampledCentre, sampledVersion == relief.version, sampledRadiusMetres == radiusMetres,
           simd_length(centerWorldMercator - sampledCentre) < radiusWorld * Self.resampleShare {
            return
        }
        guard let span = Self.spanMetres(centerWorldMercator: centerWorldMercator, radiusWorld: radiusWorld, read: {
            relief.elevation(atNormalizedWorld: $0, terrainZoom: relief.cameraTerrainZoom)
        }) else {
            return
        }
        sampledSpanMetres = span
        sampledCentre = centerWorldMercator
        sampledVersion = relief.version
        sampledRadiusMetres = radiusMetres
    }

    /// The highest less the lowest of the heights `read` answers at the
    /// centre and on the two rings, nil when fewer than two points have
    /// terrain under them.
    static func spanMetres(centerWorldMercator: SIMD2<Double>,
                           radiusWorld: Double,
                           read: (SIMD2<Double>) -> Float?) -> Float? {
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude
        var count = 0
        func take(_ point: SIMD2<Double>) {
            guard let metres = read(point) else { return }
            lowest = min(lowest, metres)
            highest = max(highest, metres)
            count += 1
        }
        take(centerWorldMercator)
        for (ringCount, radius) in [(outerRingCount, radiusWorld), (innerRingCount, radiusWorld * 0.5)] {
            for index in 0 ..< ringCount {
                let angle = Double(index) / Double(ringCount) * 2 * Double.pi
                take(centerWorldMercator + SIMD2<Double>(cos(angle), sin(angle)) * radius)
            }
        }
        guard count >= 2 else { return nil }
        return highest - lowest
    }

    /// The share of the way from the smoothed span to the sampled one a
    /// frame of `deltaTime` goes: half the way every `halfLife` seconds,
    /// all of it with no half-life.
    static func smoothingShare(deltaTime: TimeInterval, halfLife: TimeInterval) -> Float {
        guard halfLife > 0, deltaTime > 0 else { return 1 }
        return Float(1 - pow(0.5, deltaTime / halfLife))
    }

    /// Where the span lies between the two thresholds, 0 to 1. With the
    /// thresholds crossed (the mountains' at or under the plain's) a step
    /// at the mountains' threshold.
    static func mountainousness(spanMetres: Float, settings: Settings) -> Float {
        let width = settings.mountainsAboveMetres - settings.plainBelowMetres
        guard width > 0 else {
            return spanMetres >= settings.mountainsAboveMetres ? 1 : 0
        }
        return min(max((spanMetres - settings.plainBelowMetres) / width, 0), 1)
    }

    /// The kind after this frame's span: mountains from the mountains'
    /// threshold up, a plain from the plain's down, and between them what
    /// it was. The first reading takes the nearer threshold's side.
    static func kind(after previous: ImmersiveMapTerrainSurroundings.Kind?,
                     spanMetres: Float,
                     settings: Settings) -> ImmersiveMapTerrainSurroundings.Kind {
        if spanMetres >= settings.mountainsAboveMetres {
            return .mountains
        }
        if spanMetres <= settings.plainBelowMetres {
            return .plain
        }
        if let previous {
            return previous
        }
        return mountainousness(spanMetres: spanMetres, settings: settings) >= 0.5 ? .mountains : .plain
    }
}
