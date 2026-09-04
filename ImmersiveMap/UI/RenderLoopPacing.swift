// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Keeps the reasons why the render loop must keep running.
/// Picks the frame rate and pause state for the `CAMetalDisplayLink` based on render loop activity.
final class RenderLoopPacing {
    enum Activity: String, CaseIterable {
        case interaction = "interaction"
        case labelFade = "label fade"
        case labelVisibilityCycle = "label visibility cycle"
        case cameraAnimation = "camera animation"
        case avatarAnimation = "avatar animation"
        case sceneModelAnimation = "scene model animation"
        case routeAnimation = "route animation"
        /// A camera position set from outside through
        /// `ImmersiveMapCameraController.jump`: an app driving the camera
        /// once per frame (its own animation, a follow camera fed by a
        /// location stream). Held for a short grace after every jump so a
        /// series of jumps keeps the display link running the way a gesture
        /// does, instead of pausing it after each one-shot frame and
        /// resuming it on the next jump, which loses vsyncs.
        case externalCameraDrive = "external camera drive"

        var usesInteractionFrameRate: Bool {
            switch self {
            case .interaction,
                 .labelVisibilityCycle,
                 .cameraAnimation,
                 .avatarAnimation,
                 .sceneModelAnimation,
                 .routeAnimation,
                 .externalCameraDrive:
                return true
            case .labelFade:
                return false
            }
        }
    }

    /// Ceilings imposed by the device's power situation, applied on top of the
    /// configured rates regardless of which activities are running.
    struct PowerConstraintState: Equatable {
        /// Hard frame-rate ceiling; nil leaves the configured rates untouched.
        var maximumFramesPerSecond: Int?
        /// Whether interaction-class activities may still ride above the
        /// configured floor to ProMotion rates.
        var allowsProMotionHeadroom: Bool

        static let unconstrained = PowerConstraintState(maximumFramesPerSecond: nil,
                                                    allowsProMotionHeadroom: true)

        /// Serious thermal pressure caps rendering at 60, critical at 30, and
        /// both revoke ProMotion headroom. Low Power Mode only revokes the
        /// headroom: the configured floor stays, so interactions remain smooth
        /// while the display stops being driven above what was asked for.
        static func resolve(thermalState: ProcessInfo.ThermalState,
                            isLowPowerModeEnabled: Bool) -> PowerConstraintState {
            var constraints = PowerConstraintState.unconstrained
            switch thermalState {
            case .serious:
                constraints.maximumFramesPerSecond = 60
            case .critical:
                constraints.maximumFramesPerSecond = 30
            case .nominal, .fair:
                break
            @unknown default:
                break
            }
            if isLowPowerModeEnabled || constraints.maximumFramesPerSecond != nil {
                constraints.allowsProMotionHeadroom = false
            }
            return constraints
        }
    }

    /// How long the loop stays awake after a camera position set from
    /// outside. Long enough that a driver at 30 Hz with jitter never lets the
    /// link pause between two sets; short enough that a lone jump costs about
    /// a dozen identical frames at 120 Hz before the link sleeps again.
    static let externalCameraDriveGraceSeconds: CFTimeInterval = 0.1

    private var configuration: ImmersiveMapSettings.RenderLoopSettings
    private var powerConstraints: PowerConstraintState = .unconstrained
    private var requestedFrameReason: RenderInvalidationReason?
    private var activeRenderingActivities: Set<Activity> = []
    private var externalCameraDriveDeadline: CFTimeInterval?
    // A view parked in the reuse pool has nothing to present into: rendering
    // is fully gated off regardless of pending requests or activities, which
    // pauses the display link. Requests and activities keep accumulating and
    // take effect again on adoption.
    private var isParked = false

    init(configuration: ImmersiveMapSettings.RenderLoopSettings) {
        self.configuration = configuration
    }

    func applyConfiguration(_ configuration: ImmersiveMapSettings.RenderLoopSettings) {
        self.configuration = configuration
    }

    func applyPowerConstraintState(_ constraints: PowerConstraintState) {
        powerConstraints = constraints
    }

    var needsFrameRendering: Bool {
        guard isParked == false else {
            return false
        }
        return configuration.forceContinuousRendering
            || requestedFrameReason != nil
            || activeRenderingActivities.isEmpty == false
    }

    func setParked(_ parked: Bool) {
        isParked = parked
    }

    var isCameraAnimationRenderingActive: Bool {
        activeRenderingActivities.contains(.cameraAnimation)
    }

    var shouldPauseDisplayLink: Bool {
        needsFrameRendering == false
    }

    var targetFramesPerSecond: Int {
        if configuration.forceContinuousRendering {
            return powerConstrained(configuration.interactionFramesPerSecond)
        }
        if activeRenderingActivities.contains(where: \.usesInteractionFrameRate) {
            return powerConstrained(configuration.interactionFramesPerSecond)
        }
        if activeRenderingActivities.contains(.labelFade) {
            return powerConstrained(configuration.labelFadeFramesPerSecond)
        }
        return 0
    }

    /// True when the current target rate comes from an interaction-class
    /// activity (or forced continuous rendering): the configured rate is a
    /// floor there and the display link may ride up to the display's maximum
    /// on ProMotion hardware. The label fade keeps its deliberately low
    /// cadence and gets no headroom, and power constraints (thermal pressure,
    /// Low Power Mode) revoke it globally.
    var allowsFrameRateHeadroom: Bool {
        guard powerConstraints.allowsProMotionHeadroom else {
            return false
        }
        return configuration.forceContinuousRendering
            || activeRenderingActivities.contains(where: \.usesInteractionFrameRate)
    }

    private func powerConstrained(_ framesPerSecond: Int) -> Int {
        guard let ceiling = powerConstraints.maximumFramesPerSecond else {
            return framesPerSecond
        }
        return min(framesPerSecond, ceiling)
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

    /// A camera position was set from outside at `now`: holds the
    /// `.externalCameraDrive` activity until the grace after it has passed.
    /// Every further set pushes the deadline.
    func noteExternalCameraDrive(at now: CFTimeInterval) {
        externalCameraDriveDeadline = now + Self.externalCameraDriveGraceSeconds
        activeRenderingActivities.insert(.externalCameraDrive)
    }

    /// Called once per display-link tick: drops the external camera drive
    /// activity once its grace has passed, so the link can pause again.
    func expireExternalCameraDrive(at now: CFTimeInterval) {
        guard let deadline = externalCameraDriveDeadline, now >= deadline else {
            return
        }
        externalCameraDriveDeadline = nil
        activeRenderingActivities.remove(.externalCameraDrive)
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
        case .sceneModelAssetLoaded:
            return "scene model asset loaded"
        case .externalStateChanged:
            return "external state changed"
        }
    }
}
