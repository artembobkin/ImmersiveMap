// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct PinVisibilityFadeResolution {
    let projectedPins: [ProjectedPin]
    let hasActiveAnimations: Bool
}

final class PinVisibilityFadeStateStore {
    static let activeAlphaThreshold: Float = 0.0001

    private struct Entry {
        var currentAlpha: Float
        var targetAlpha: Float
        var lastUpdateTime: TimeInterval
    }

    private var entriesById: [UInt64: Entry] = [:]
    /// Fully visible pins from the previous frame that carry no state (passthrough),
    /// in ascending id order: when they dim, their fade starts from one.
    private var previouslyFullyVisibleIDs: [UInt64] = []
    private(set) var hasActiveAnimations: Bool = false

    func resolve(projectedPins: [ProjectedPin],
                 time: TimeInterval,
                 fadeInSeconds: TimeInterval,
                 fadeOutSeconds: TimeInterval) -> PinVisibilityFadeResolution {
        var resolvedPins: [ProjectedPin] = []
        resolvedPins.reserveCapacity(projectedPins.count)
        var seenIds = Set<UInt64>()
        var fullyVisibleIDs: [UInt64] = []
        fullyVisibleIDs.reserveCapacity(projectedPins.count)
        var hasActiveAnimations = false

        for projectedPin in projectedPins where projectedPin.screenPoint.visible != 0 {
            let id = projectedPin.pin.id
            let targetAlpha = simd_clamp(projectedPin.screenPoint.visibilityAlpha, 0.0, 1.0)

            // A fully visible pin without fade state passes straight through:
            // this is the common case for all flat-mode pins, no state is
            // created and the dictionary is untouched.
            if targetAlpha >= 1.0, entriesById.isEmpty || entriesById[id] == nil {
                fullyVisibleIDs.append(id)
                resolvedPins.append(projectedPin)
                continue
            }

            seenIds.insert(id)
            var entry: Entry
            if let existing = entriesById[id] {
                entry = existing
            } else if Self.containsSorted(previouslyFullyVisibleIDs, id) {
                // Was passthrough-visible: the fade starts at full alpha.
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

            // State that has reached full visibility is dropped: from here the
            // pin takes the free passthrough path.
            if isActive == false, targetAlpha >= 1.0, entry.currentAlpha >= 1.0 {
                entriesById.removeValue(forKey: id)
                fullyVisibleIDs.append(id)
                resolvedPins.append(projectedPin)
                continue
            }

            let shouldRender = entry.currentAlpha > Self.activeAlphaThreshold ||
                targetAlpha > Self.activeAlphaThreshold ||
                isActive

            if shouldRender {
                var screenPoint = projectedPin.screenPoint
                screenPoint.visibilityAlpha = entry.currentAlpha
                resolvedPins.append(ProjectedPin(pin: projectedPin.pin,
                                                             squashScale: projectedPin.squashScale,
                                                             screenPoint: screenPoint,
                                                             drawOrder: projectedPin.drawOrder))
                hasActiveAnimations = hasActiveAnimations || isActive
            }
            entriesById[id] = entry
        }

        if entriesById.isEmpty == false {
            for id in Array(entriesById.keys) where seenIds.contains(id) == false {
                entriesById.removeValue(forKey: id)
            }
        }

        // Input arrives in ascending id order, but arbitrary callers may
        // pass it otherwise - binary search requires sortedness.
        if fullyVisibleIDs.count > 1 {
            for index in 1..<fullyVisibleIDs.count where fullyVisibleIDs[index - 1] > fullyVisibleIDs[index] {
                fullyVisibleIDs.sort()
                break
            }
        }
        previouslyFullyVisibleIDs = fullyVisibleIDs

        self.hasActiveAnimations = hasActiveAnimations
        return PinVisibilityFadeResolution(projectedPins: resolvedPins,
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
