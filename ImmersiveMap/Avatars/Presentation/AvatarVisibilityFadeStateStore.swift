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
    private(set) var hasActiveAnimations: Bool = false

    func resolve(projectedMarkers: [AvatarProjectedMarker],
                 time: TimeInterval,
                 fadeInSeconds: TimeInterval,
                 fadeOutSeconds: TimeInterval) -> AvatarVisibilityFadeResolution {
        var resolvedMarkers: [AvatarProjectedMarker] = []
        resolvedMarkers.reserveCapacity(projectedMarkers.count)
        var seenIds = Set<UInt64>()
        var hasActiveAnimations = false

        for projectedMarker in projectedMarkers where projectedMarker.screenPoint.visible != 0 {
            let id = projectedMarker.marker.id
            seenIds.insert(id)
            let targetAlpha = simd_clamp(projectedMarker.screenPoint.visibilityAlpha, 0.0, 1.0)
            var entry = entriesById[id] ?? Entry(currentAlpha: targetAlpha,
                                                 targetAlpha: targetAlpha,
                                                 lastUpdateTime: time)
            advance(&entry,
                    to: entry.targetAlpha,
                    currentTime: time,
                    fadeInSeconds: fadeInSeconds,
                    fadeOutSeconds: fadeOutSeconds)
            entry.targetAlpha = targetAlpha
            entry.lastUpdateTime = time

            let isActive = isActive(entry)
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

        for id in Array(entriesById.keys) where seenIds.contains(id) == false {
            entriesById.removeValue(forKey: id)
        }

        self.hasActiveAnimations = hasActiveAnimations
        return AvatarVisibilityFadeResolution(projectedMarkers: resolvedMarkers,
                                              hasActiveAnimations: hasActiveAnimations)
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
