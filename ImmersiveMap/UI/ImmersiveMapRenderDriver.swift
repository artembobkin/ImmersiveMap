// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import QuartzCore

/// Manages the map's render loop at the view level: holds the
/// `CAMetalDisplayLink` built from the host view's `CAMetalLayer`, enables or
/// pauses it based on `RenderLoopPacing` state, and invokes
/// `RenderFrameEngine.render(to:drawable:)` with the drawable each link update
/// delivers. The system hands the drawable together with the tick, so frames
/// never block in `nextDrawable()` mid-encode, and the link paces wakeups
/// against actual drawable availability (the update also carries presentation
/// deadlines, which is what makes ProMotion pacing exact). Does not own
/// `RenderFrameEngine` and does not manage render settings.
final class ImmersiveMapRenderDriver: NSObject {
    typealias Activity = RenderLoopPacing.Activity

    private var pacing: RenderLoopPacing
    private var displayLink: CAMetalDisplayLink?
    private var displayLinkDelegate: MetalDisplayLinkBridge?
    private weak var renderer: RenderFrameEngine?

    init(configuration: ImmersiveMapSettings.RenderLoopSettings) {
        self.pacing = RenderLoopPacing(configuration: configuration)
        super.init()
    }

    var cameraAnimationRenderingActive: Bool {
        pacing.isCameraAnimationRenderingActive
    }

    /// The layer must already carry its Metal device (the renderer is created
    /// before the loop starts): the link is built from the layer and follows
    /// it for the lifetime of the driver, across renderer recreations and
    /// window moves alike.
    @MainActor
    func start(frameDelegate: ImmersiveMapRenderDriverFrameDelegate,
               layer: CAMetalLayer) {
        guard displayLink == nil else { return }

        let bridge = MetalDisplayLinkBridge(driver: self,
                                            frameDelegate: frameDelegate)
        displayLinkDelegate = bridge
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = bridge
        link.add(to: .main, forMode: .common)
        displayLink = link
        applyDisplayLinkState()
    }

    func attachRenderer(_ renderer: RenderFrameEngine) {
        self.renderer = renderer
    }

    func detachRenderer() {
        renderer = nil
    }

    /// Applies new frame-rate/continuity settings to an already running display link.
    func updateRenderLoopSettings(_ settings: ImmersiveMapSettings.RenderLoopSettings) {
        performOnMain {
            self.updatePacing {
                self.pacing.applyConfiguration(settings)
            }
        }
    }

    /// Applies thermal/Low Power ceilings on top of the configured rates.
    func applyPowerConstraintState(_ constraints: RenderLoopPacing.PowerConstraintState) {
        performOnMain {
            self.updatePacing {
                self.pacing.applyPowerConstraintState(constraints)
            }
        }
    }

    func requestFrame(reason: RenderInvalidationReason) {
        performOnMain {
            self.updatePacing {
                self.pacing.requestOneFrame(reason: reason)
            }
        }
    }

    func setActivity(_ activity: Activity,
                     active: Bool) {
        performOnMain {
            self.updatePacing {
                self.pacing.setRenderingActivity(activity,
                                                 isActive: active)
            }
        }
    }

    /// Parks/unparks the render loop for the view-reuse pool: while parked the
    /// display link is paused no matter what work is pending.
    func setParked(_ parked: Bool) {
        performOnMain {
            self.updatePacing {
                self.pacing.setParked(parked)
            }
        }
    }

    func stop() {
        // Full teardown (host-runtime deinit / pool drop): the engine is being
        // discarded with the driver: stop its tile loader and cut late event
        // deliveries before the reference is dropped.
        renderer?.prepareForDiscard()
        displayLink?.invalidate()
        displayLink = nil
        displayLinkDelegate = nil
    }

    #if DEBUG
    /// See `RenderFrameEngine.debugCameraSample`.
    var debugCameraSample: (zoom: Double, centerX: Double, centerY: Double)? {
        renderer?.debugCameraSample
    }

    /// See `RenderFrameEngine.debugFrameSkipCounts`.
    var debugFrameCounters: (scheduled: Int, skips: [String: Int]) {
        (renderer?.debugScheduledFrameCount ?? 0, renderer?.debugFrameSkipCounts ?? [:])
    }
    #endif

    func beginFrame() -> Bool {
        guard pacing.needsFrameRendering else {
            applyDisplayLinkState()
            return false
        }

        return true
    }

    func continueFrameAfterPreparation() -> Bool {
        guard pacing.needsFrameRendering else {
            applyDisplayLinkState()
            return false
        }

        return true
    }

    @discardableResult
    func renderFrame(layer: CAMetalLayer,
                     drawable: any CAMetalDrawable,
                     isRenderable: Bool) -> Bool {
        guard isRenderable else {
            applyDisplayLinkState()
            return false
        }

        let didSchedule = renderer?.render(to: layer, drawable: drawable) ?? false
        if didSchedule {
            pacing.consumeOneFrameRequest()
        }
        applyDisplayLinkState()
        return didSchedule
    }

    /// Upper bound offered to the display link for interaction-class
    /// activities: the highest refresh rate ProMotion panels ship on iPhone,
    /// iPad, and MacBook Pro. Non-ProMotion hardware clamps the range to its
    /// own maximum, so the offer is a no-op there. On iPhone, rates above 60
    /// additionally require the host app to declare
    /// `CADisableMinimumFrameDurationOnPhone` in its Info.plist; without it
    /// the system keeps the 60 Hz cap.
    private static let proMotionMaximumFramesPerSecond: Float = 120

    private func applyDisplayLinkState() {
        let targetFramesPerSecond = pacing.targetFramesPerSecond
        if targetFramesPerSecond > 0 {
            // The configured rate is the floor. Interaction-class activities
            // may ride up to ProMotion rates on both platforms; the label
            // fade keeps its narrow low-power cadence.
            let maximumFramesPerSecond = pacing.allowsFrameRateHeadroom
                ? max(Float(targetFramesPerSecond), Self.proMotionMaximumFramesPerSecond)
                : Float(targetFramesPerSecond)
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(targetFramesPerSecond),
                                                                    maximum: maximumFramesPerSecond,
                                                                    preferred: maximumFramesPerSecond)
        } else {
            displayLink?.preferredFrameRateRange = .default
        }
        displayLink?.isPaused = pacing.shouldPauseDisplayLink
    }

    private func updatePacing(_ update: () -> Void) {
        update()
        applyDisplayLinkState()
    }

    deinit {
        stop()
    }
}

@MainActor
protocol ImmersiveMapRenderDriverFrameDelegate: AnyObject {
    func renderDriverDidTick(_ driver: ImmersiveMapRenderDriver,
                             currentTime: CFTimeInterval,
                             drawable: any CAMetalDrawable)
}

/// Weak delegate bridge for `CAMetalDisplayLink`. The link holds its delegate
/// weakly and the bridge holds the driver and frame delegate weakly, so the
/// display link never retains the render stack. A skipped update simply drops
/// its drawable, which returns to the layer's pool on release.
///
/// The link is added to the main runloop, so updates always arrive on the
/// main thread; the `@preconcurrency` conformance carries that guarantee into
/// the delegate method (the runtime asserts main-actor isolation on entry).
@MainActor
private final class MetalDisplayLinkBridge: NSObject, @preconcurrency CAMetalDisplayLinkDelegate {
    private weak var driver: ImmersiveMapRenderDriver?
    private weak var frameDelegate: ImmersiveMapRenderDriverFrameDelegate?
    #if DEBUG && os(macOS)
    private let presentTimingProbe = RenderPresentTimingProbe.makeIfEnabled()
    #endif

    init(driver: ImmersiveMapRenderDriver,
         frameDelegate: ImmersiveMapRenderDriverFrameDelegate) {
        self.driver = driver
        self.frameDelegate = frameDelegate
        #if DEBUG && os(macOS)
        presentTimingProbe?.begin(driver: driver)
        #endif
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink,
                          needsUpdate update: CAMetalDisplayLink.Update) {
        guard let driver else { return }

        // Animations sample at the update's presentation time (the moment
        // this frame is predicted to appear on the display), not at "now"
        // and not at targetTimestamp, which is the deadline for finishing
        // the render: that is the time the frame is going to be seen at.
        let renderFrame: () -> Void = { [frameDelegate] in
            frameDelegate?.renderDriverDidTick(driver,
                                               currentTime: update.targetPresentationTimestamp,
                                               drawable: update.drawable)
        }
        #if DEBUG && os(macOS)
        if let presentTimingProbe {
            presentTimingProbe.recordTick(target: update.targetPresentationTimestamp,
                                          drawable: update.drawable,
                                          driver: driver,
                                          frameWork: renderFrame)
            return
        }
        #endif
        renderFrame()
    }
}
