// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Keeps the reasons why the render loop must keep running.
/// Picks the frame rate and pause state for the `CADisplayLink` based on render loop activity.
final class RenderLoopPacing {
    enum Activity: String, CaseIterable {
        case interaction = "interaction"
        case labelFade = "label fade"
        case labelVisibilityCycle = "label visibility cycle"
        case cameraAnimation = "camera animation"
        case avatarAnimation = "avatar animation"

        var usesInteractionFrameRate: Bool {
            switch self {
            case .interaction,
                 .labelVisibilityCycle,
                 .cameraAnimation,
                 .avatarAnimation:
                return true
            case .labelFade:
                return false
            }
        }
    }

    private var configuration: ImmersiveMapSettings.RenderLoopSettings
    private var requestedFrameReason: RenderInvalidationReason?
    private var activeRenderingActivities: Set<Activity> = []

    init(configuration: ImmersiveMapSettings.RenderLoopSettings) {
        self.configuration = configuration
    }

    func applyConfiguration(_ configuration: ImmersiveMapSettings.RenderLoopSettings) {
        self.configuration = configuration
    }

    var needsFrameRendering: Bool {
        configuration.forceContinuousRendering
            || requestedFrameReason != nil
            || activeRenderingActivities.isEmpty == false
    }

    var isCameraAnimationRenderingActive: Bool {
        activeRenderingActivities.contains(.cameraAnimation)
    }

    var shouldPauseDisplayLink: Bool {
        needsFrameRendering == false
    }

    var targetFramesPerSecond: Int {
        if configuration.forceContinuousRendering {
            return configuration.interactionFramesPerSecond
        }
        if activeRenderingActivities.contains(where: \.usesInteractionFrameRate) {
            return configuration.interactionFramesPerSecond
        }
        if activeRenderingActivities.contains(.labelFade) {
            return configuration.labelFadeFramesPerSecond
        }
        return 0
    }

    func requestOneFrame(reason: RenderInvalidationReason) {
        requestedFrameReason = reason
    }

    func setRenderingActivity(_ activity: Activity,
                              isActive: Bool) {
        if isActive {
            activeRenderingActivities.insert(activity)
        } else {
            activeRenderingActivities.remove(activity)
        }
    }

    func consumeOneFrameRequest() {
        requestedFrameReason = nil
    }

    var renderingReasonDescription: String? {
        var reasons: [String] = []
        if configuration.forceContinuousRendering {
            reasons.append("force continuous rendering")
        }
        if let requestedFrameReason {
            reasons.append("pending frame: \(requestedFrameReason.description)")
        }
        reasons.append(contentsOf: Activity.allCases
            .filter { activeRenderingActivities.contains($0) }
            .map(\.rawValue))
        return reasons.isEmpty ? nil : reasons.joined(separator: ", ")
    }
}

private extension RenderInvalidationReason {
    var description: String {
        switch self {
        case .tileAvailable:
            return "tile available"
        case .tileRetryDue:
            return "tile retry due"
        case .externalStateChanged:
            return "external state changed"
        }
    }
}
