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

/// Кешируемая тригонометрия проекции геокоординаты: пересчитывается только
/// при смене координаты, пер-кадровая проекция 30k маркеров остаётся линейной
/// (без sin/cos/log на маркер на кадр).
struct AvatarProjectionBasis {
    /// Единичный вектор точки на сфере в системе формулы глобуса
    /// (до вращения панорамы): (cosLat*sinLon, sinLat, cosLat*cosLon).
    let sphereUnit: SIMD3<Float>
    /// (lon + pi) / 2pi - нормализованный X мировой развёртки.
    let normalizedWorldX: Double
    /// Нормализованный меркаторный Y широты.
    let mercatorYNormalized: Double

    init(coordinate: GeoCoordinate) {
        let latitude = coordinate.latitude * .pi / 180.0
        let longitude = coordinate.longitude * .pi / 180.0
        let cosLatitude = cos(latitude)
        sphereUnit = SIMD3<Float>(Float(cosLatitude * sin(longitude)),
                                  Float(sin(latitude)),
                                  Float(cosLatitude * cos(longitude)))
        normalizedWorldX = (longitude + .pi) / (2.0 * .pi)
        mercatorYNormalized = ImmersiveMapProjection.yMercatorNormalized(latitude: latitude)
    }
}

struct PresentedAvatarMarker {
    var marker: AvatarMarker
    var squashScale: SIMD2<Float>
    var drawOrder: Int
    var projectionBasis: AvatarProjectionBasis
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
    var projectionBasis: AvatarProjectionBasis
    var animation: AvatarPositionAnimation?
    var selectionAnimationStartTime: TimeInterval?

    init(marker: AvatarMarker, time: TimeInterval) {
        self.marker = marker
        self.displayedCoordinate = marker.coordinate
        self.projectionBasis = AvatarProjectionBasis(coordinate: marker.coordinate)
        self.animation = nil
        self.selectionAnimationStartTime = marker.isSelected ? time : nil
    }

    /// Смена показываемой координаты пересчитывает проекционный базис -
    /// единственное место с тригонометрией на маркер.
    private mutating func moveDisplayedCoordinate(to coordinate: GeoCoordinate) {
        guard coordinate.latitude != displayedCoordinate.latitude
                || coordinate.longitude != displayedCoordinate.longitude else {
            return
        }
        displayedCoordinate = coordinate
        projectionBasis = AvatarProjectionBasis(coordinate: coordinate)
    }

    mutating func presentedAvatar(at time: TimeInterval, drawOrder: Int) -> PresentedAvatarMarker {
        if let animation {
            moveDisplayedCoordinate(to: animation.coordinate(at: time))
            if animation.isFinished(at: time) {
                moveDisplayedCoordinate(to: animation.targetCoordinate)
                self.animation = nil
            }
        }

        var marker = marker
        marker.coordinate = displayedCoordinate
        let squashScale = selectionSquashScale(at: time)
        return PresentedAvatarMarker(marker: marker,
                                     squashScale: squashScale,
                                     drawOrder: drawOrder,
                                     projectionBasis: projectionBasis)
    }

    mutating func update(with marker: AvatarMarker,
                         time: TimeInterval) {
        let previousTargetCoordinate = self.marker.coordinate
        let hasCoordinateChange = previousTargetCoordinate.latitude != marker.coordinate.latitude
            || previousTargetCoordinate.longitude != marker.coordinate.longitude
        if hasCoordinateChange {
            let startCoordinate = presentedAvatar(at: time, drawOrder: 0).marker.coordinate
            let duration = AvatarAnimationMath.animationDuration(from: startCoordinate,
                                                                 to: marker.coordinate)
            moveDisplayedCoordinate(to: startCoordinate)
            animation = duration > 0
                ? AvatarPositionAnimation(startCoordinate: startCoordinate,
                                          targetCoordinate: marker.coordinate,
                                          startTime: time,
                                          duration: duration)
                : nil
            if duration == 0 {
                moveDisplayedCoordinate(to: marker.coordinate)
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

    func hasActiveAnimations(at time: TimeInterval) -> Bool {
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

/// Стор презентации маркеров: держит записи по возрастанию id и кеш
/// presented-списка. Пер-кадровая цена пропорциональна числу АНИМИРУЮЩИХСЯ
/// маркеров (обычно единицы), а не общему количеству: статичные 30k маркеров
/// между мутациями обходятся возвратом кешированного массива.
final class AvatarPresentationStateStore {
    private var entries: [AvatarPresentationEntry] = []
    private var drawOrders: [Int] = []
    private var presentedCache: [PresentedAvatarMarker] = []
    private var animatingIndices: [Int] = []
    private(set) var hasActiveAnimations: Bool = false

    init() {}

    func apply(snapshot: AvatarsSnapshot, time: TimeInterval) {
        var previousEntriesByID = Dictionary<UInt64, AvatarPresentationEntry>(minimumCapacity: entries.count)
        for entry in entries {
            previousEntriesByID[entry.marker.id] = entry
        }

        let sortedMarkers = snapshot.markers.sorted { $0.id < $1.id }
        entries = sortedMarkers.map { marker in
            if var existing = previousEntriesByID[marker.id] {
                existing.update(with: marker, time: time)
                return existing
            }
            return AvatarPresentationEntry(marker: marker, time: time)
        }

        // Ранги порядка отрисовки по (drawPriority, id) фиксируются на
        // мутации: solver получает вход, уже отсортированный по id, с готовым
        // drawOrder - без пер-кадровой сортировки.
        let rankedIndexes = entries.indices.sorted { lhs, rhs in
            if entries[lhs].marker.drawPriority != entries[rhs].marker.drawPriority {
                return entries[lhs].marker.drawPriority < entries[rhs].marker.drawPriority
            }
            return entries[lhs].marker.id < entries[rhs].marker.id
        }
        drawOrders = [Int](repeating: 0, count: entries.count)
        for (rank, index) in rankedIndexes.enumerated() {
            drawOrders[index] = rank
        }

        presentedCache = entries.indices.map { index in
            entries[index].presentedAvatar(at: time, drawOrder: drawOrders[index])
        }
        animatingIndices = entries.indices.filter { entries[$0].hasActiveAnimations(at: time) }
        hasActiveAnimations = animatingIndices.isEmpty == false
    }

    func presentedMarkers(at time: TimeInterval) -> [AvatarMarker] {
        presentedEntries(at: time).map(\.marker)
    }

    /// Возвращает presented-список по возрастанию id (drawOrder - в поле).
    /// Вызывающий не должен удерживать массив между кадрами: кеш обновляется
    /// на месте, удержание вызвало бы COW-копию всех маркеров.
    func presentedEntries(at time: TimeInterval) -> [PresentedAvatarMarker] {
        guard animatingIndices.isEmpty == false else {
            hasActiveAnimations = false
            return presentedCache
        }

        var stillAnimating: [Int] = []
        stillAnimating.reserveCapacity(animatingIndices.count)
        for index in animatingIndices {
            presentedCache[index] = entries[index].presentedAvatar(at: time,
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
