// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  BaseLabelPresentationStateStore.swift
//  ImmersiveMap
//

import Foundation

struct BaseLabelPresentationResolution {
    let fadeAlphas: [Float]
    let hasActiveAnimations: Bool
}

struct BaseLabelPresentationInput {
    static let empty = BaseLabelPresentationInput(labelKey: 0,
                                                  duplicate: 0,
                                                  isRetained: 0,
                                                  isValid: false,
                                                  minCameraZoom: 0)

    let labelKey: UInt64
    let duplicate: UInt8
    let isRetained: UInt8
    let isValid: Bool
    /// Минимальный зум камеры, с которого лейбл виден (0 = всегда).
    let minCameraZoom: Float
}

final class BaseLabelPresentationStateStore {
    private struct Entry {
        var currentAlpha: Float
        var targetAlpha: Float
        var lastUpdateTime: TimeInterval
        var lastSeenFrameIndex: UInt64
    }

    private var entries: [UInt64: Entry] = [:]

    func resolveAlphas(inputs: [BaseLabelPresentationInput],
                       collisionFlags: [UInt32],
                       time: TimeInterval,
                       frameIndex: UInt64,
                       fadeInSeconds: TimeInterval,
                       fadeOutSeconds: TimeInterval) -> BaseLabelPresentationResolution {
        let targetVisibility = inputs.indices.map { index in
            let input = inputs[index]
            let collisionHidden = index < collisionFlags.count ? (collisionFlags[index] != 0) : false
            return input.isValid && input.duplicate == 0 && input.isRetained == 0 && collisionHidden == false
        }
        return resolveAlphas(inputs: inputs,
                             targetVisibility: targetVisibility,
                             time: time,
                             frameIndex: frameIndex,
                             fadeInSeconds: fadeInSeconds,
                             fadeOutSeconds: fadeOutSeconds)
    }

    func resolveAlphas(inputs: [BaseLabelPresentationInput],
                       targetVisibility: [Bool],
                       time: TimeInterval,
                       frameIndex: UInt64,
                       fadeInSeconds: TimeInterval,
                       fadeOutSeconds: TimeInterval) -> BaseLabelPresentationResolution {
        var resolved = Array(repeating: Float(0), count: inputs.count)
        var hasActiveAnimations = false
        var seenEntryCount = 0

        for index in inputs.indices {
            let input = inputs[index]
            guard input.isValid else {
                continue
            }

            if input.duplicate != 0 {
                resolved[index] = 0
                continue
            }

            let isVisibleTarget = index < targetVisibility.count ? targetVisibility[index] : false
            let targetAlpha: Float = isVisibleTarget ? 1 : 0
            let alphaResolution = resolveAlpha(labelKey: input.labelKey,
                                               targetAlpha: targetAlpha,
                                               time: time,
                                               frameIndex: frameIndex,
                                               fadeInSeconds: fadeInSeconds,
                                               fadeOutSeconds: fadeOutSeconds)
            resolved[index] = alphaResolution.alpha
            hasActiveAnimations = hasActiveAnimations || alphaResolution.isActive
            if alphaResolution.firstTouchThisFrame {
                seenEntryCount += 1
            }
        }

        // Скан устаревших записей нужен только когда этим кадром увидены не все:
        // при стабильной топологии (обычный кадр) он пропускается целиком.
        if seenEntryCount < entries.count {
            hasActiveAnimations = fadeOutMissingEntries(currentTime: time,
                                                        frameIndex: frameIndex,
                                                        fadeInSeconds: fadeInSeconds,
                                                        fadeOutSeconds: fadeOutSeconds) || hasActiveAnimations
        }
        return BaseLabelPresentationResolution(fadeAlphas: resolved,
                                               hasActiveAnimations: hasActiveAnimations)
    }

    func currentAlphas(inputs: [BaseLabelPresentationInput],
                       time: TimeInterval,
                       fadeInSeconds: TimeInterval,
                       fadeOutSeconds: TimeInterval) -> [Float] {
        inputs.map { input in
            guard input.isValid,
                  input.duplicate == 0,
                  let entry = entries[input.labelKey] else {
                return 0
            }

            var advanced = entry
            Self.advance(&advanced,
                         to: advanced.targetAlpha,
                         currentTime: time,
                         fadeInSeconds: fadeInSeconds,
                         fadeOutSeconds: fadeOutSeconds)
            return advanced.currentAlpha
        }
    }

    func reset() {
        entries.removeAll(keepingCapacity: false)
    }

    private func resolveAlpha(labelKey: UInt64,
                              targetAlpha: Float,
                              time: TimeInterval,
                              frameIndex: UInt64,
                              fadeInSeconds: TimeInterval,
                              fadeOutSeconds: TimeInterval) -> (alpha: Float, isActive: Bool, firstTouchThisFrame: Bool) {
        // Один modify-доступ к словарю вместо get+put (два хеш-лукапа на
        // инстанс на кадр). lastSeenFrameIndex дефолта смещён на -1, чтобы
        // свежесозданная запись считалась первым касанием кадра.
        Self.resolveEntry(&entries[labelKey, default: Entry(currentAlpha: 0,
                                                            targetAlpha: 0,
                                                            lastUpdateTime: time,
                                                            lastSeenFrameIndex: frameIndex &- 1)],
                          targetAlpha: targetAlpha,
                          time: time,
                          frameIndex: frameIndex,
                          fadeInSeconds: fadeInSeconds,
                          fadeOutSeconds: fadeOutSeconds)
    }

    private static func resolveEntry(_ entry: inout Entry,
                                     targetAlpha: Float,
                                     time: TimeInterval,
                                     frameIndex: UInt64,
                                     fadeInSeconds: TimeInterval,
                                     fadeOutSeconds: TimeInterval) -> (alpha: Float, isActive: Bool, firstTouchThisFrame: Bool) {
        let firstTouchThisFrame = entry.lastSeenFrameIndex != frameIndex
        advance(&entry,
                to: entry.targetAlpha,
                currentTime: time,
                fadeInSeconds: fadeInSeconds,
                fadeOutSeconds: fadeOutSeconds)
        entry.targetAlpha = targetAlpha
        entry.lastSeenFrameIndex = frameIndex
        entry.lastUpdateTime = time
        return (entry.currentAlpha, isActive: isActive(entry), firstTouchThisFrame: firstTouchThisFrame)
    }

    private func fadeOutMissingEntries(currentTime: TimeInterval,
                                       frameIndex: UInt64,
                                       fadeInSeconds: TimeInterval,
                                       fadeOutSeconds: TimeInterval) -> Bool {
        guard entries.isEmpty == false else {
            return false
        }

        let staleKeys = entries.compactMap { key, entry in
            entry.lastSeenFrameIndex == frameIndex ? nil : key
        }
        var hasActiveAnimations = false

        for key in staleKeys {
            guard var entry = entries[key] else {
                continue
            }

            Self.advance(&entry,
                         to: entry.targetAlpha,
                         currentTime: currentTime,
                         fadeInSeconds: fadeInSeconds,
                         fadeOutSeconds: fadeOutSeconds)
            entry.targetAlpha = 0
            entry.lastUpdateTime = currentTime
            hasActiveAnimations = hasActiveAnimations || Self.isActive(entry)

            if entry.currentAlpha <= 0.0001 {
                entries.removeValue(forKey: key)
            } else {
                entries[key] = entry
            }
        }

        return hasActiveAnimations
    }

    private static func advance(_ entry: inout Entry,
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

    private static func isActive(_ entry: Entry) -> Bool {
        abs(entry.currentAlpha - entry.targetAlpha) > 0.001
    }
}
