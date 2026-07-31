// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import QuartzCore

/// Creates the `CADisplayLink` for the driver: on iOS the link is system-wide,
/// on macOS it is vended by `NSView` and tied to the host view window's display.
typealias DisplayLinkFactory = (_ target: Any, _ selector: Selector) -> CADisplayLink

/// Manages the map's render loop at the view level: holds the `CADisplayLink`,
/// enables or pauses it based on `RenderLoopPacing` state,
/// and invokes `RenderFrameEngine.render(to:)`.
/// Does not own `RenderFrameEngine` and does not manage render settings.
final class ImmersiveMapRenderDriver: NSObject {
    typealias Activity = RenderLoopPacing.Activity

    private var pacing: RenderLoopPacing
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: WeakDisplayLinkTarget?
    private weak var renderer: RenderFrameEngine?

    init(configuration: ImmersiveMapSettings.RenderLoopSettings) {
        self.pacing = RenderLoopPacing(configuration: configuration)
        super.init()
    }

    var cameraAnimationRenderingActive: Bool {
        pacing.isCameraAnimationRenderingActive
    }

    func start(frameDelegate: ImmersiveMapRenderDriverFrameDelegate,
               displayLinkFactory: DisplayLinkFactory) {
        guard displayLink == nil else { return }

        let target = WeakDisplayLinkTarget(driver: self,
                                           frameDelegate: frameDelegate)
        displayLinkTarget = target
        displayLink = displayLinkFactory(target,
                                         #selector(WeakDisplayLinkTarget.displayLinkDidFire(_:)))
        displayLink?.add(to: .main, forMode: .common)
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

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }

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
                     isRenderable: Bool) -> Bool {
        guard isRenderable else {
            applyDisplayLinkState()
            return false
        }

        let didSchedule = renderer?.render(to: layer) ?? false
        if didSchedule {
            pacing.consumeOneFrameRequest()
        }
        applyDisplayLinkState()
        return didSchedule
    }

    private func applyDisplayLinkState() {
        #if canImport(UIKit)
        displayLink?.preferredFramesPerSecond = pacing.targetFramesPerSecond
        #else
        // On macOS CADisplayLink has no preferredFramesPerSecond - only the range API.
        let targetFramesPerSecond = pacing.targetFramesPerSecond
        if targetFramesPerSecond > 0 {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(targetFramesPerSecond),
                                                                    maximum: Float(targetFramesPerSecond),
                                                                    preferred: Float(targetFramesPerSecond))
        } else {
            displayLink?.preferredFrameRateRange = .default
        }
        #endif
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
                             currentTime: CFTimeInterval)
}

/// Weak proxy target for `CADisplayLink`.
/// Keeps the display link from retaining the render driver or frame delegate.
private final class WeakDisplayLinkTarget: NSObject {
    private weak var driver: ImmersiveMapRenderDriver?
    private weak var frameDelegate: ImmersiveMapRenderDriverFrameDelegate?

    init(driver: ImmersiveMapRenderDriver,
         frameDelegate: ImmersiveMapRenderDriverFrameDelegate) {
        self.driver = driver
        self.frameDelegate = frameDelegate
    }

    // @MainActor: the display link is added to the main runloop, the tick is always on main.
    @MainActor @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard let driver else { return }

        frameDelegate?.renderDriverDidTick(driver,
                                           currentTime: CACurrentMediaTime())
    }
}
