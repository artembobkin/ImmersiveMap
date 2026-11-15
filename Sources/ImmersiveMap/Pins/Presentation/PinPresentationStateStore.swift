// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  PinPresentationStateStore.swift
//  ImmersiveMap
//

import Foundation
import simd

enum PinAnimationMath {
    static let minimumDuration: TimeInterval = 0.14
    static let maximumDuration: TimeInterval = 0.60
    static let saturationDistanceMeters: Double = 250.0
    static let minimumAnimatedDistanceMeters: Double = 0.01

    static func animationDuration(from start: GeoCoordinate,
                                  to target: GeoCoordinate) -> TimeInterval {
        let distance = geodesicDistanceMeters(from: start, to: target)
        guard distance > minimumAnimatedDistanceMeters else {
            return 0
        }

        let normalized = min(max(distance / saturationDistanceMeters, 0), 1)
        let eased = pow(normalized, 0.6)
        return minimumDuration + (maximumDuration - minimumDuration) * eased
    }

    static func coordinate(from start: GeoCoordinate,
                           to target: GeoCoordinate,
                           progress: Double) -> GeoCoordinate {
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else { return start }
        guard clampedProgress < 1 else { return target }

        let fromVector = unitVector(for: start)
        let toVector = unitVector(for: target)
        let dotProduct = min(max(simd_dot(fromVector, toVector), Float(-1)), Float(1))
        if dotProduct > 0.9995 {
            let blended = simd_normalize(fromVector + (toVector - fromVector) * Float(clampedProgress))
            return coordinate(for: blended)
        }
        if dotProduct < -0.9995 {
            return fallbackCoordinate(from: start, to: target, progress: clampedProgress)
        }

        let angle = acos(Double(dotProduct))
        let sinAngle = sin(angle)
        guard sinAngle > Double.leastNonzeroMagnitude else {
            return target
        }

        let startWeight = sin((1 - clampedProgress) * angle) / sinAngle
        let targetWeight = sin(clampedProgress * angle) / sinAngle
        let blended = simd_normalize(fromVector * Float(startWeight) + toVector * Float(targetWeight))
        return coordinate(for: blended)
    }

    static func easedProgress(for rawProgress: Double) -> Double {
        let clamped = min(max(rawProgress, 0), 1)
        let inverse = 1 - clamped
        return 1 - inverse * inverse * inverse
    }

    private static func geodesicDistanceMeters(from start: GeoCoordinate,
                                               to target: GeoCoordinate) -> Double {
        let latitude1 = start.latitude * .pi / 180.0
        let latitude2 = target.latitude * .pi / 180.0
        let latitudeDelta = latitude2 - latitude1
        let longitudeDelta = (target.longitude - start.longitude) * .pi / 180.0
        let sinLatitude = sin(latitudeDelta * 0.5)
        let sinLongitude = sin(longitudeDelta * 0.5)
        let a = sinLatitude * sinLatitude
            + cos(latitude1) * cos(latitude2) * sinLongitude * sinLongitude
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return 6_371_000.0 * c
    }

    private static func unitVector(for coordinate: GeoCoordinate) -> SIMD3<Float> {
        let latitude = coordinate.latitude * .pi / 180.0
        let longitude = coordinate.longitude * .pi / 180.0
        let cosLatitude = cos(latitude)
        return SIMD3<Float>(Float(cosLatitude * cos(longitude)),
                            Float(cosLatitude * sin(longitude)),
                            Float(sin(latitude)))
    }

    private static func coordinate(for vector: SIMD3<Float>) -> GeoCoordinate {
        let normalized = simd_normalize(vector)
        let latitude = atan2(Double(normalized.z),
                             sqrt(Double(normalized.x * normalized.x + normalized.y * normalized.y)))
        let longitude = atan2(Double(normalized.y), Double(normalized.x))
        return GeoCoordinate(latitude: latitude * 180.0 / .pi,
                             longitude: longitude * 180.0 / .pi)
    }

    private static func fallbackCoordinate(from start: GeoCoordinate,
                                           to target: GeoCoordinate,
                                           progress: Double) -> GeoCoordinate {
        let latitude = start.latitude + (target.latitude - start.latitude) * progress
        let longitudeDelta = shortestLongitudeDelta(from: start.longitude, to: target.longitude)
        let longitude = normalizedLongitude(start.longitude + longitudeDelta * progress)
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func shortestLongitudeDelta(from start: Double, to target: Double) -> Double {
        var delta = normalizedLongitude(target) - normalizedLongitude(start)
        if delta > 180 {
            delta -= 360
        } else if delta < -180 {
            delta += 360
        }
        return delta
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        var normalized = longitude.truncatingRemainder(dividingBy: 360)
        if normalized > 180 {
            normalized -= 360
        } else if normalized < -180 {
            normalized += 360
        }
        return normalized
    }
}

enum PinSelectionAnimationMath {
    static let cycleDuration: TimeInterval = 0.90
    static let entryDuration: TimeInterval = 0.18
    static let minimumScale: Float = 0.94

    static func squashScale(at elapsed: TimeInterval) -> SIMD2<Float> {
        guard cycleDuration > 0 else {
            return SIMD2<Float>(repeating: 1.0)
        }

        let phase = normalizedCycleProgress(for: elapsed) * 2.0 * .pi - (.pi / 2.0)
        let horizontalCompressionShare = 0.5 * (1.0 + sin(phase))
        let verticalCompressionShare = 1.0 - horizontalCompressionShare
        let compressionAmplitude = (1.0 - Double(minimumScale)) * entryEnvelope(for: elapsed)
        let horizontalCompression = compressionAmplitude * horizontalCompressionShare
        let verticalCompression = compressionAmplitude * verticalCompressionShare

        return SIMD2<Float>(Float(1.0 - horizontalCompression),
                            Float(1.0 - verticalCompression))
    }

    private static func normalizedCycleProgress(for elapsed: TimeInterval) -> Double {
        let normalized = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        let positive = normalized < 0 ? normalized + cycleDuration : normalized
        return positive / cycleDuration
    }

    private static func entryEnvelope(for elapsed: TimeInterval) -> Double {
        guard entryDuration > 0 else {
            return 1.0
        }

        let clamped = min(max(elapsed / entryDuration, 0), 1)
        return 0.5 - 0.5 * cos(clamped * .pi)
    }
}

struct PresentedPin {
    var pin: ImmersiveMapPin
    var squashScale: SIMD2<Float>
    var drawOrder: Int
    var projectionBasis: GeoProjectionBasis
}

private struct PinPositionAnimation {
    let startCoordinate: GeoCoordinate
    let targetCoordinate: GeoCoordinate
    let startTime: TimeInterval
    let duration: TimeInterval

    func coordinate(at time: TimeInterval) -> GeoCoordinate {
        guard duration > 0 else { return targetCoordinate }
        let rawProgress = (time - startTime) / duration
        let progress = PinAnimationMath.easedProgress(for: rawProgress)
        return PinAnimationMath.coordinate(from: startCoordinate,
                                              to: targetCoordinate,
                                              progress: progress)
    }

    func isFinished(at time: TimeInterval) -> Bool {
        time >= startTime + duration
    }
}

private struct PinPresentationEntry {
    var pin: ImmersiveMapPin
    var displayedCoordinate: GeoCoordinate
    var projectionBasis: GeoProjectionBasis
    var animation: PinPositionAnimation?
    var selectionAnimationStartTime: TimeInterval?

    init(pin: ImmersiveMapPin, time: TimeInterval) {
        self.pin = pin
        self.displayedCoordinate = pin.coordinate
        self.projectionBasis = GeoProjectionBasis(coordinate: pin.coordinate)
        self.animation = nil
        self.selectionAnimationStartTime = pin.isSelected ? time : nil
    }

    /// Changing the presented coordinate recomputes the projection basis:
    /// the only place with per-pin trigonometry.
    private mutating func moveDisplayedCoordinate(to coordinate: GeoCoordinate) {
        guard coordinate.latitude != displayedCoordinate.latitude
                || coordinate.longitude != displayedCoordinate.longitude else {
            return
        }
        displayedCoordinate = coordinate
        projectionBasis = GeoProjectionBasis(coordinate: coordinate)
    }

    mutating func presentedPin(at time: TimeInterval, drawOrder: Int) -> PresentedPin {
        if let animation {
            moveDisplayedCoordinate(to: animation.coordinate(at: time))
            if animation.isFinished(at: time) {
                moveDisplayedCoordinate(to: animation.targetCoordinate)
                self.animation = nil
            }
        }

        var pin = pin
        pin.coordinate = displayedCoordinate
        let squashScale = selectionSquashScale(at: time)
        return PresentedPin(pin: pin,
                                     squashScale: squashScale,
                                     drawOrder: drawOrder,
                                     projectionBasis: projectionBasis)
    }

    mutating func update(with pin: ImmersiveMapPin,
                         time: TimeInterval) {
        let previousTargetCoordinate = self.pin.coordinate
        let hasCoordinateChange = previousTargetCoordinate.latitude != pin.coordinate.latitude
            || previousTargetCoordinate.longitude != pin.coordinate.longitude
        if hasCoordinateChange {
            let startCoordinate = presentedPin(at: time, drawOrder: 0).pin.coordinate
            let duration = PinAnimationMath.animationDuration(from: startCoordinate,
                                                                 to: pin.coordinate)
            moveDisplayedCoordinate(to: startCoordinate)
            animation = duration > 0
                ? PinPositionAnimation(startCoordinate: startCoordinate,
                                          targetCoordinate: pin.coordinate,
                                          startTime: time,
                                          duration: duration)
                : nil
            if duration == 0 {
                moveDisplayedCoordinate(to: pin.coordinate)
            }
        }

        let selectionChanged = self.pin.isSelected != pin.isSelected
        if selectionChanged {
            selectionAnimationStartTime = pin.isSelected ? time : nil
        } else if pin.isSelected, selectionAnimationStartTime == nil {
            selectionAnimationStartTime = time
        }

        self.pin = pin
    }

    func hasActiveAnimations(at time: TimeInterval) -> Bool {
        animation != nil || pin.isSelected
    }

    private func selectionSquashScale(at time: TimeInterval) -> SIMD2<Float> {
        guard pin.isSelected,
              let selectionAnimationStartTime else {
            return SIMD2<Float>(repeating: 1.0)
        }

        return PinSelectionAnimationMath.squashScale(at: time - selectionAnimationStartTime)
    }

}

/// Pin presentation store: keeps entries sorted by ascending id plus a
/// cached presented list. Per-frame cost is proportional to the number of
/// ANIMATING pins (usually a handful), not the total count: 30k static
/// pins between mutations cost only returning the cached array.
final class PinPresentationStateStore {
    private var entries: [PinPresentationEntry] = []
    private var drawOrders: [Int] = []
    private var presentedCache: [PresentedPin] = []
    private var animatingIndices: [Int] = []
    private(set) var hasActiveAnimations: Bool = false

    init() {}

    func apply(snapshot: PinsSnapshot, time: TimeInterval) {
        var previousEntriesByID = Dictionary<UInt64, PinPresentationEntry>(minimumCapacity: entries.count)
        for entry in entries {
            previousEntriesByID[entry.pin.id] = entry
        }

        let sortedPins = snapshot.pins.sorted { $0.id < $1.id }
        entries = sortedPins.map { pin in
            if var existing = previousEntriesByID[pin.id] {
                existing.update(with: pin, time: time)
                return existing
            }
            return PinPresentationEntry(pin: pin, time: time)
        }

        // Draw-order ranks by (drawPriority, id) are fixed at mutation time:
        // the solver receives input already sorted by id with a precomputed
        // drawOrder, no per-frame sorting.
        let rankedIndexes = entries.indices.sorted { lhs, rhs in
            if entries[lhs].pin.drawPriority != entries[rhs].pin.drawPriority {
                return entries[lhs].pin.drawPriority < entries[rhs].pin.drawPriority
            }
            return entries[lhs].pin.id < entries[rhs].pin.id
        }
        drawOrders = [Int](repeating: 0, count: entries.count)
        for (rank, index) in rankedIndexes.enumerated() {
            drawOrders[index] = rank
        }

        presentedCache = entries.indices.map { index in
            entries[index].presentedPin(at: time, drawOrder: drawOrders[index])
        }
        animatingIndices = entries.indices.filter { entries[$0].hasActiveAnimations(at: time) }
        hasActiveAnimations = animatingIndices.isEmpty == false
    }

    func presentedPins(at time: TimeInterval) -> [ImmersiveMapPin] {
        presentedEntries(at: time).map(\.pin)
    }

    /// Returns the presented list sorted by ascending id (drawOrder is a field).
    /// The caller must not retain the array across frames: the cache is updated
    /// in place, and retaining it would trigger a COW copy of all pins.
    func presentedEntries(at time: TimeInterval) -> [PresentedPin] {
        guard animatingIndices.isEmpty == false else {
            hasActiveAnimations = false
            return presentedCache
        }

        var stillAnimating: [Int] = []
        stillAnimating.reserveCapacity(animatingIndices.count)
        for index in animatingIndices {
            presentedCache[index] = entries[index].presentedPin(at: time,
                                                                   drawOrder: drawOrders[index])
            if entries[index].hasActiveAnimations(at: time) {
                stillAnimating.append(index)
            }
        }
        animatingIndices = stillAnimating
        hasActiveAnimations = stillAnimating.isEmpty == false
        return presentedCache
    }
}
