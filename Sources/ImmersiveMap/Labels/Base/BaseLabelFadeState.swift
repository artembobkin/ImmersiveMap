// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The fade alpha of every label of a working set, index-aligned with the
/// set: no dictionary, no per-frame allocation. The arrays are sized once
/// when the set changes (`rebind`), carrying each surviving tile's run of
/// alphas to its new place, so a tile that moves in the set keeps its
/// fades; a frame then only advances the alphas in place.
///
/// A target set this frame takes effect from the next frame on: the alpha
/// first moves toward the previous target over the time elapsed, then the
/// new target is stored, so a label that flips its decision mid-fade
/// finishes the step it was on before turning around.
final class BaseLabelFadeState {
    private(set) var currentAlphas: [Float] = []
    private var targetAlphas: [Float] = []
    private var lastUpdateTimes: [TimeInterval] = []

    var count: Int {
        currentAlphas.count
    }

    /// Binds the state to a set of `change.count` labels. A run that
    /// survived the change keeps its alphas, targets and times at its new
    /// place; everything else starts invisible, with `time` as its last
    /// update so the first advance moves nothing. Allocates once per call,
    /// which happens on a topology change only.
    func rebind(change: LabelWorkingSetChange, time: TimeInterval) {
        currentAlphas = change.carry(currentAlphas, initial: 0)
        targetAlphas = change.carry(targetAlphas, initial: 0)
        lastUpdateTimes = change.carry(lastUpdateTimes, initial: time)
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
        let count = currentAlphas.count
        guard count > 0 else {
            return false
        }
        let fadeIn = max(0, fadeInSeconds)
        let fadeOut = max(0, fadeOutSeconds)
        var hasActiveAnimations = false
        currentAlphas.withUnsafeMutableBufferPointer { alphas in
        targetAlphas.withUnsafeMutableBufferPointer { targets in
        lastUpdateTimes.withUnsafeMutableBufferPointer { times in
        targetVisibility.withUnsafeBufferPointer { visibility in
            let visibleCount = visibility.count
            var index = 0
            while index < count {
                let elapsed = time - times[index]
                let target = targets[index]
                var alpha = alphas[index]
                if elapsed > 0 {
                    if target > alpha {
                        if fadeIn == 0 {
                            alpha = target
                        } else {
                            let next = alpha + Float(elapsed / fadeIn)
                            alpha = next < target ? next : target
                        }
                    } else if target < alpha {
                        if fadeOut == 0 {
                            alpha = target
                        } else {
                            let next = alpha - Float(elapsed / fadeOut)
                            alpha = next > target ? next : target
                        }
                    }
                }
                let nextTarget: Float = index < visibleCount && visibility[index] ? 1 : 0
                alphas[index] = alpha
                targets[index] = nextTarget
                times[index] = time
                let delta = alpha - nextTarget
                if delta > 0.001 || delta < -0.001 {
                    hasActiveAnimations = true
                }
                index += 1
            }
        }}}}
        return hasActiveAnimations
    }

    /// The collision solve found `loser` to be a copy of `winner` (the same
    /// feature from another tile, drawn at the same point): the winner
    /// takes the fuller alpha of the two so a change of winner shows no
    /// blink, and the loser goes out at once, not through a fade, or the
    /// text would draw twice while it faded.
    func transfer(from loser: Int, to winner: Int) {
        guard loser != winner,
              loser >= 0, loser < currentAlphas.count,
              winner >= 0, winner < currentAlphas.count else {
            return
        }
        if currentAlphas[loser] > currentAlphas[winner] {
            currentAlphas[winner] = currentAlphas[loser]
            targetAlphas[winner] = targetAlphas[loser]
            lastUpdateTimes[winner] = lastUpdateTimes[loser]
        }
        currentAlphas[loser] = 0
        targetAlphas[loser] = 0
    }

    func reset() {
        currentAlphas.removeAll(keepingCapacity: false)
        targetAlphas.removeAll(keepingCapacity: false)
        lastUpdateTimes.removeAll(keepingCapacity: false)
    }
}
