// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A route resolved for the current frame: the tessellated path plus the
/// displayed (possibly animated) progress and style.
struct PresentedRoute {
    let id: UInt64
    /// Tessellated path samples, rebuilt only when the path itself changes.
    let samples: [GeoPathSample]
    let color: SIMD4<Float>
    let widthPoints: Double
    let progress: Double
}

private struct RouteProgressAnimation {
    let startProgress: Double
    let targetProgress: Double
    let startTime: TimeInterval
    let duration: TimeInterval

    /// Cubic ease-out, the same curve the scene model and avatar stores use.
    /// Kept local so `Routes` does not depend on a sibling domain folder.
    private static func easedProgress(for rawProgress: Double) -> Double {
        let clamped = min(max(rawProgress, 0), 1)
        let inverse = 1 - clamped
        return 1 - inverse * inverse * inverse
    }

    func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return targetProgress }
        let eased = Self.easedProgress(for: (time - startTime) / duration)
        return startProgress + (targetProgress - startProgress) * eased
    }

    func isFinished(at time: TimeInterval) -> Bool {
        time >= startTime + duration
    }
}

private struct RoutePresentationEntry {
    var route: ImmersiveMapRoute
    /// Tessellation is the expensive part (trigonometry per sample), so it is
    /// recomputed only when the path value changes, not when the style or the
    /// progress does.
    var samples: [GeoPathSample]
    var displayedProgress: Double
    var progressAnimation: RouteProgressAnimation?

    init(route: ImmersiveMapRoute) {
        self.route = route
        samples = GeoPathSampler.samples(for: route.path)
        displayedProgress = min(max(route.progress, 0), 1)
        progressAnimation = nil
    }

    mutating func update(with route: ImmersiveMapRoute,
                         progressDuration: TimeInterval,
                         time: TimeInterval) {
        if self.route.path != route.path {
            samples = GeoPathSampler.samples(for: route.path)
        }

        let target = min(max(route.progress, 0), 1)
        if target != min(max(self.route.progress, 0), 1) {
            // Settle the in-flight animation to the current time so the new
            // segment starts from what is on screen, not from a stale target.
            _ = presentedRoute(at: time)
            if progressDuration > 0 {
                progressAnimation = RouteProgressAnimation(startProgress: displayedProgress,
                                                           targetProgress: target,
                                                           startTime: time,
                                                           duration: progressDuration)
            } else {
                progressAnimation = nil
                displayedProgress = target
            }
        }

        self.route = route
    }

    mutating func presentedRoute(at time: TimeInterval) -> PresentedRoute {
        if let progressAnimation {
            displayedProgress = progressAnimation.progress(at: time)
            if progressAnimation.isFinished(at: time) {
                displayedProgress = progressAnimation.targetProgress
                self.progressAnimation = nil
            }
        }

        return PresentedRoute(id: route.id,
                              samples: samples,
                              color: route.color,
                              widthPoints: route.widthPoints,
                              progress: displayedProgress)
    }

    func hasActiveAnimations(at time: TimeInterval) -> Bool {
        progressAnimation != nil
    }
}

/// Route presentation store: keeps entries sorted by ascending id plus a cached
/// presented list. Per-frame cost is proportional to the number of ANIMATING
/// routes, not the total count.
final class RoutePresentationStateStore {
    private var entries: [RoutePresentationEntry] = []
    private var presentedCache: [PresentedRoute] = []
    private var animatingIndices: [Int] = []
    private(set) var hasActiveAnimations: Bool = false

    var isEmpty: Bool {
        entries.isEmpty
    }

    init() {}

    func apply(snapshot: RoutesSnapshot, time: TimeInterval) {
        var previousEntriesByID = Dictionary<UInt64, RoutePresentationEntry>(minimumCapacity: entries.count)
        for entry in entries {
            previousEntriesByID[entry.route.id] = entry
        }

        let sortedRoutes = snapshot.routes.sorted { $0.id < $1.id }
        entries = sortedRoutes.map { route in
            if var existing = previousEntriesByID[route.id] {
                existing.update(with: route,
                                progressDuration: snapshot.progressAnimationDurationsById[route.id] ?? 0,
                                time: time)
                return existing
            }
            return RoutePresentationEntry(route: route)
        }

        presentedCache = entries.indices.map { entries[$0].presentedRoute(at: time) }
        animatingIndices = entries.indices.filter { entries[$0].hasActiveAnimations(at: time) }
        hasActiveAnimations = animatingIndices.isEmpty == false
    }

    /// Returns the presented list sorted by ascending id. The caller must not
    /// retain the array across frames: the cache is updated in place.
    func presentedEntries(at time: TimeInterval) -> [PresentedRoute] {
        guard animatingIndices.isEmpty == false else {
            hasActiveAnimations = false
            return presentedCache
        }

        var stillAnimating: [Int] = []
        stillAnimating.reserveCapacity(animatingIndices.count)
        for index in animatingIndices {
            presentedCache[index] = entries[index].presentedRoute(at: time)
            if entries[index].hasActiveAnimations(at: time) {
                stillAnimating.append(index)
            }
        }
        animatingIndices = stillAnimating
        hasActiveAnimations = stillAnimating.isEmpty == false
        return presentedCache
    }
}
