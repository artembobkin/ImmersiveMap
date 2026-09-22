// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The fade alpha of every label of a working set, index-aligned with the
/// set: no dictionary, no per-frame allocation. The arrays are sized once
/// when the set changes (`rebind`), carrying each label's alpha over by its
/// key so a tile that moves in the set keeps its fades; a frame then only
/// advances the alphas in place.
///
/// A target set this frame takes effect from the next frame on: the alpha
/// first moves toward the previous target over the time elapsed, then the
/// new target is stored, so a label that flips its decision mid-fade
/// finishes the step it was on before turning around.
final class BaseLabelFadeState {
    private(set) var keys: [UInt64] = []
    private(set) var currentAlphas: [Float] = []
    private var targetAlphas: [Float] = []
    private var lastUpdateTimes: [TimeInterval] = []

    var count: Int {
        keys.count
    }

    /// Binds the state to `newKeys`. A label whose key was in the old set
    /// keeps its alpha and target; a new one starts invisible. Labels no
    /// longer in the set are dropped (their tiles are gone, nothing draws
    /// them). Key 0 is the cache's placeholder for an empty slot and never
    /// carries state. Allocates once per call, which happens on a topology
    /// change only.
    ///
    /// A key can sit at several indices: the same feature arrives in an
    /// exact tile and in the coarser tile standing in next to it, or a road
    /// crosses two tiles. Only one of those copies is ever shown, and the
    /// others sit at alpha 0. The copy that carries over is the one with the
    /// most alpha, whatever its index: taking the first index instead
    /// handed the shown copy the hidden copy's zero on every tile change
    /// under a tilted camera, so the label vanished and faded back in.
    func rebind(keys newKeys: [UInt64], time: TimeInterval) {
        guard newKeys != keys else {
            return
        }
        var previousByKey: [UInt64: (alpha: Float, target: Float, updated: TimeInterval)] = [:]
        previousByKey.reserveCapacity(keys.count)
        for index in keys.indices where keys[index] != 0 {
            let candidate = (alpha: currentAlphas[index], target: targetAlphas[index], updated: lastUpdateTimes[index])
            if let existing = previousByKey[keys[index]] {
                if candidate.alpha > existing.alpha
                    || (candidate.alpha == existing.alpha && candidate.target > existing.target) {
                    previousByKey[keys[index]] = candidate
                }
            } else {
                previousByKey[keys[index]] = candidate
            }
        }
        var nextCurrent = [Float](repeating: 0, count: newKeys.count)
        var nextTarget = [Float](repeating: 0, count: newKeys.count)
        var nextUpdated = [TimeInterval](repeating: time, count: newKeys.count)
        for index in newKeys.indices {
            guard newKeys[index] != 0, let previous = previousByKey[newKeys[index]] else {
                continue
            }
            nextCurrent[index] = previous.alpha
            nextTarget[index] = previous.target
            nextUpdated[index] = previous.updated
        }
        keys = newKeys
        currentAlphas = nextCurrent
        targetAlphas = nextTarget
        lastUpdateTimes = nextUpdated
    }

    /// Advances every label toward its stored target over the time since
    /// its last update, then stores `targetVisibility` as the new target.
    /// Returns whether any label is still mid-fade. `targetVisibility` must
    /// be index-aligned with the set; a missing entry counts as hidden.
    @discardableResult
    func advance(targetVisibility: [Bool],
                 time: TimeInterval,
                 fadeInSeconds: TimeInterval,
                 fadeOutSeconds: TimeInterval) -> Bool {
        var hasActiveAnimations = false
        let fadeIn = max(0, fadeInSeconds)
        let fadeOut = max(0, fadeOutSeconds)
        for index in keys.indices {
            let elapsed = max(0, time - lastUpdateTimes[index])
            let target = targetAlphas[index]
            var alpha = currentAlphas[index]
            if elapsed > 0 {
                if target > alpha {
                    alpha = fadeIn == 0 ? target : min(target, alpha + Float(elapsed / fadeIn))
                } else if target < alpha {
                    alpha = fadeOut == 0 ? target : max(target, alpha - Float(elapsed / fadeOut))
                }
            }
            let nextTarget: Float = index < targetVisibility.count && targetVisibility[index] ? 1 : 0
            currentAlphas[index] = alpha
            targetAlphas[index] = nextTarget
            lastUpdateTimes[index] = time
            if abs(alpha - nextTarget) > 0.001 {
                hasActiveAnimations = true
            }
        }
        return hasActiveAnimations
    }

    func reset() {
        keys.removeAll(keepingCapacity: false)
        currentAlphas.removeAll(keepingCapacity: false)
        targetAlphas.removeAll(keepingCapacity: false)
        lastUpdateTimes.removeAll(keepingCapacity: false)
    }
}
