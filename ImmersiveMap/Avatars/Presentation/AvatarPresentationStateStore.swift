// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarPresentationStateStore.swift
//  ImmersiveMap
//

import Foundation
import simd

enum AvatarAnimationMath {
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

enum AvatarSelectionAnimationMath {
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

struct PresentedAvatarMarker {
    var marker: AvatarMarker
    var squashScale: SIMD2<Float>
}

private struct AvatarPositionAnimation {
    let startCoordinate: GeoCoordinate
    let targetCoordinate: GeoCoordinate
    let startTime: TimeInterval
    let duration: TimeInterval

    func coordinate(at time: TimeInterval) -> GeoCoordinate {
        guard duration > 0 else { return targetCoordinate }
        let rawProgress = (time - startTime) / duration
        let progress = AvatarAnimationMath.easedProgress(for: rawProgress)
        return AvatarAnimationMath.coordinate(from: startCoordinate,
                                              to: targetCoordinate,
                                              progress: progress)
    }

    func isFinished(at time: TimeInterval) -> Bool {
        time >= startTime + duration
    }
}

private struct AvatarPresentationEntry {
    var marker: AvatarMarker
    var displayedCoordinate: GeoCoordinate
    var animation: AvatarPositionAnimation?
    var selectionAnimationStartTime: TimeInterval?

    mutating func presentedAvatar(at time: TimeInterval) -> PresentedAvatarMarker {
        if let animation {
            let coordinate = animation.coordinate(at: time)
            displayedCoordinate = coordinate
            if animation.isFinished(at: time) {
                displayedCoordinate = animation.targetCoordinate
                self.animation = nil
            }
        }

        var marker = marker
        marker.coordinate = displayedCoordinate
        let squashScale = selectionSquashScale(at: time)
        return PresentedAvatarMarker(marker: marker,
                                     squashScale: squashScale)
    }

    mutating func update(with marker: AvatarMarker,
                         time: TimeInterval) {
        let previousTargetCoordinate = self.marker.coordinate
        let hasCoordinateChange = previousTargetCoordinate.latitude != marker.coordinate.latitude
            || previousTargetCoordinate.longitude != marker.coordinate.longitude
        if hasCoordinateChange {
            let startCoordinate = presentedAvatar(at: time).marker.coordinate
            let duration = AvatarAnimationMath.animationDuration(from: startCoordinate,
                                                                 to: marker.coordinate)
            displayedCoordinate = startCoordinate
            animation = duration > 0
                ? AvatarPositionAnimation(startCoordinate: startCoordinate,
                                          targetCoordinate: marker.coordinate,
                                          startTime: time,
                                          duration: duration)
                : nil
            if duration == 0 {
                displayedCoordinate = marker.coordinate
            }
        }

        let selectionChanged = self.marker.isSelected != marker.isSelected
        if selectionChanged {
            selectionAnimationStartTime = marker.isSelected ? time : nil
        } else if marker.isSelected, selectionAnimationStartTime == nil {
            selectionAnimationStartTime = time
        }

        self.marker = marker
    }

    mutating func hasActiveAnimations(at time: TimeInterval) -> Bool {
        animation != nil || marker.isSelected
    }

    private func selectionSquashScale(at time: TimeInterval) -> SIMD2<Float> {
        guard marker.isSelected,
              let selectionAnimationStartTime else {
            return SIMD2<Float>(repeating: 1.0)
        }

        return AvatarSelectionAnimationMath.squashScale(at: time - selectionAnimationStartTime)
    }

}

final class AvatarPresentationStateStore {
    private var entriesById: [UInt64: AvatarPresentationEntry] = [:]
    private(set) var hasActiveAnimations: Bool = false

    init() {}

    func apply(snapshot: AvatarsSnapshot, time: TimeInterval) {
        for id in snapshot.removedIds {
            entriesById.removeValue(forKey: id)
        }

        for marker in snapshot.markers {
            if var entry = entriesById[marker.id] {
                entry.update(with: marker, time: time)
                entriesById[marker.id] = entry
            } else {
                entriesById[marker.id] = AvatarPresentationEntry(marker: marker,
                                                                 displayedCoordinate: marker.coordinate,
                                                                 animation: nil,
                                                                 selectionAnimationStartTime: marker.isSelected ? time : nil)
            }
        }
    }

    func presentedMarkers(at time: TimeInterval) -> [AvatarMarker] {
        presentedEntries(at: time).map(\.marker)
    }

    func presentedEntries(at time: TimeInterval) -> [PresentedAvatarMarker] {
        var markers: [PresentedAvatarMarker] = []
        markers.reserveCapacity(entriesById.count)
        hasActiveAnimations = false

        let orderedIDs = entriesById.values
            .sorted { lhs, rhs in
                if lhs.marker.drawPriority != rhs.marker.drawPriority {
                    return lhs.marker.drawPriority < rhs.marker.drawPriority
                }
                return lhs.marker.id < rhs.marker.id
            }
            .map(\.marker.id)

        for id in orderedIDs {
            guard var entry = entriesById[id] else { continue }
            let marker = entry.presentedAvatar(at: time)
            hasActiveAnimations = hasActiveAnimations || entry.hasActiveAnimations(at: time)
            entriesById[id] = entry
            markers.append(marker)
        }

        return markers
    }
}
