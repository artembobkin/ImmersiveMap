// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import Foundation
import QuartzCore

/// Управляет циклом отрисовки карты на уровне view: держит `CADisplayLink`,
/// включает или приостанавливает его по состоянию `RenderLoopPacing`,
/// и запускает `RenderFrameEngine.render(to:)`.
/// Не владеет `RenderFrameEngine` и не управляет настройками рендера.
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

    func start(frameDelegate: ImmersiveMapRenderDriverFrameDelegate) {
        guard displayLink == nil else { return }

        let target = WeakDisplayLinkTarget(driver: self,
                                           frameDelegate: frameDelegate)
        displayLinkTarget = target
        displayLink = CADisplayLink(target: target,
                                    selector: #selector(WeakDisplayLinkTarget.displayLinkDidFire(_:)))
        displayLink?.add(to: .main, forMode: .common)
        applyDisplayLinkState()
    }

    func attachRenderer(_ renderer: RenderFrameEngine) {
        self.renderer = renderer
    }

    func detachRenderer() {
        renderer = nil
    }

    /// Применяет новые настройки частоты/непрерывности отрисовки к уже запущенному display link.
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
        displayLink?.preferredFramesPerSecond = pacing.targetFramesPerSecond
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

protocol ImmersiveMapRenderDriverFrameDelegate: AnyObject {
    func renderDriverDidTick(_ driver: ImmersiveMapRenderDriver,
                             currentTime: CFTimeInterval)
}

/// Weak proxy target для `CADisplayLink`.
/// Не дает display link удерживать render driver или frame delegate.
private final class WeakDisplayLinkTarget: NSObject {
    private weak var driver: ImmersiveMapRenderDriver?
    private weak var frameDelegate: ImmersiveMapRenderDriverFrameDelegate?

    init(driver: ImmersiveMapRenderDriver,
         frameDelegate: ImmersiveMapRenderDriverFrameDelegate) {
        self.driver = driver
        self.frameDelegate = frameDelegate
    }

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard let driver else { return }

        frameDelegate?.renderDriverDidTick(driver,
                                           currentTime: CACurrentMediaTime())
    }
}

#endif
