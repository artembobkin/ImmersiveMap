// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct AvatarVisibilityFadeResolution {
    let projectedMarkers: [AvatarProjectedMarker]
    let hasActiveAnimations: Bool
}

final class AvatarVisibilityFadeStateStore {
    static let activeAlphaThreshold: Float = 0.0001

    private struct Entry {
        var currentAlpha: Float
        var targetAlpha: Float
        var lastUpdateTime: TimeInterval
    }

    private var entriesById: [UInt64: Entry] = [:]
    /// Прошлокадровые полностью видимые маркеры без состояния (passthrough),
    /// по возрастанию id: при затемнении их фейд стартует с единицы.
    private var previouslyFullyVisibleIDs: [UInt64] = []
    private(set) var hasActiveAnimations: Bool = false

    func resolve(projectedMarkers: [AvatarProjectedMarker],
                 time: TimeInterval,
                 fadeInSeconds: TimeInterval,
                 fadeOutSeconds: TimeInterval) -> AvatarVisibilityFadeResolution {
        var resolvedMarkers: [AvatarProjectedMarker] = []
        resolvedMarkers.reserveCapacity(projectedMarkers.count)
        var seenIds = Set<UInt64>()
        var fullyVisibleIDs: [UInt64] = []
        fullyVisibleIDs.reserveCapacity(projectedMarkers.count)
        var hasActiveAnimations = false

        for projectedMarker in projectedMarkers where projectedMarker.screenPoint.visible != 0 {
            let id = projectedMarker.marker.id
            let targetAlpha = simd_clamp(projectedMarker.screenPoint.visibilityAlpha, 0.0, 1.0)

            // Полностью видимый маркер без фейд-состояния проходит насквозь:
            // это типовой случай для всех маркеров плоского режима, состояние
            // не создаётся и словарь не трогается.
            if targetAlpha >= 1.0, entriesById.isEmpty || entriesById[id] == nil {
                fullyVisibleIDs.append(id)
                resolvedMarkers.append(projectedMarker)
                continue
            }

            seenIds.insert(id)
            var entry: Entry
            if let existing = entriesById[id] {
                entry = existing
            } else if Self.containsSorted(previouslyFullyVisibleIDs, id) {
                // Был passthrough-видимым: фейд стартует с полной альфы.
                entry = Entry(currentAlpha: 1.0, targetAlpha: 1.0, lastUpdateTime: time)
            } else {
                entry = Entry(currentAlpha: targetAlpha, targetAlpha: targetAlpha, lastUpdateTime: time)
            }
            advance(&entry,
                    to: entry.targetAlpha,
                    currentTime: time,
                    fadeInSeconds: fadeInSeconds,
                    fadeOutSeconds: fadeOutSeconds)
            entry.targetAlpha = targetAlpha
            entry.lastUpdateTime = time

            let isActive = isActive(entry)

            // Дошедшее до полной видимости состояние снимается: дальше маркер
            // идёт по бесплатному passthrough-пути.
            if isActive == false, targetAlpha >= 1.0, entry.currentAlpha >= 1.0 {
                entriesById.removeValue(forKey: id)
                fullyVisibleIDs.append(id)
                resolvedMarkers.append(projectedMarker)
                continue
            }

            let shouldRender = entry.currentAlpha > Self.activeAlphaThreshold ||
                targetAlpha > Self.activeAlphaThreshold ||
                isActive

            if shouldRender {
                var screenPoint = projectedMarker.screenPoint
                screenPoint.visibilityAlpha = entry.currentAlpha
                resolvedMarkers.append(AvatarProjectedMarker(marker: projectedMarker.marker,
                                                             squashScale: projectedMarker.squashScale,
                                                             screenPoint: screenPoint,
                                                             drawOrder: projectedMarker.drawOrder))
                hasActiveAnimations = hasActiveAnimations || isActive
            }
            entriesById[id] = entry
        }

        if entriesById.isEmpty == false {
            for id in Array(entriesById.keys) where seenIds.contains(id) == false {
                entriesById.removeValue(forKey: id)
            }
        }

        // Вход идёт по возрастанию id, но произвольные вызывающие могут
        // передать иначе - бинарный поиск требует сортированности.
        if fullyVisibleIDs.count > 1 {
            for index in 1..<fullyVisibleIDs.count where fullyVisibleIDs[index - 1] > fullyVisibleIDs[index] {
                fullyVisibleIDs.sort()
                break
            }
        }
        previouslyFullyVisibleIDs = fullyVisibleIDs

        self.hasActiveAnimations = hasActiveAnimations
        return AvatarVisibilityFadeResolution(projectedMarkers: resolvedMarkers,
                                              hasActiveAnimations: hasActiveAnimations)
    }

    private static func containsSorted(_ sortedIDs: [UInt64], _ id: UInt64) -> Bool {
        var low = 0
        var high = sortedIDs.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if sortedIDs[middle] == id {
                return true
            } else if sortedIDs[middle] < id {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return false
    }

    private func advance(_ entry: inout Entry,
                         to targetAlpha: Float,
                         currentTime: TimeInterval,
                         fadeInSeconds: TimeInterval,
                         fadeOutSeconds: TimeInterval) {
        let elapsed = max(0, currentTime - entry.lastUpdateTime)
        guard elapsed > 0 else {
            return
        }

        if targetAlpha > entry.currentAlpha {
            let duration = max(0, fadeInSeconds)
            if duration == 0 {
                entry.currentAlpha = targetAlpha
            } else {
                let step = Float(elapsed / duration)
                entry.currentAlpha = min(targetAlpha, entry.currentAlpha + step)
            }
        } else if targetAlpha < entry.currentAlpha {
            let duration = max(0, fadeOutSeconds)
            if duration == 0 {
                entry.currentAlpha = targetAlpha
            } else {
                let step = Float(elapsed / duration)
                entry.currentAlpha = max(targetAlpha, entry.currentAlpha - step)
            }
        }
    }

    private func isActive(_ entry: Entry) -> Bool {
        abs(entry.currentAlpha - entry.targetAlpha) > 0.001
    }
}
