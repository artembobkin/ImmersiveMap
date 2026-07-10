// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit

/// Владеет жестами основного полотна карты на macOS и переводит события AppKit
/// в команды камеры, выбора и render-loop для `ImmersiveMapNSView`.
///
/// Раскладка ввода:
/// - перетаскивание левой кнопкой - пан; с зажатой ⌥ - pitch/bearing;
/// - перетаскивание правой кнопкой - pitch/bearing;
/// - трекпад pinch - зум, трекпад rotate - поворот;
/// - scroll wheel / двухпальцевый скролл - зум (обрабатывает host view через `handleScrollWheel`);
/// - клик - выбор объекта или background tap.
@MainActor
final class MapGestureController: NSObject, NSGestureRecognizerDelegate {
    private enum PanMode {
        case pan
        case tilt
    }

    private enum ScrollZoom {
        /// Точный (трекпадный) скролл: полный свайп ~150pt = 1 уровень зума.
        static let preciseDivisor: CGFloat = 150.0
        /// Дискретное колесо мыши: scrollingDeltaY ~10 за щелчок, ~0.33 зума на щелчок.
        static let lineDivisor: CGFloat = 30.0
    }

    private weak var mapView: ImmersiveMapNSView?
    let panGesture: NSPanGestureRecognizer
    private let tiltPanGesture: NSPanGestureRecognizer
    private let clickGesture: NSClickGestureRecognizer
    private let rotationGesture: NSRotationGestureRecognizer
    private let magnificationGesture: NSMagnificationGestureRecognizer
    private var panMode: PanMode = .pan

    init(mapView: ImmersiveMapNSView) {
        self.mapView = mapView
        self.panGesture = NSPanGestureRecognizer()
        self.tiltPanGesture = NSPanGestureRecognizer()
        self.clickGesture = NSClickGestureRecognizer()
        self.rotationGesture = NSRotationGestureRecognizer()
        self.magnificationGesture = NSMagnificationGestureRecognizer()
        super.init()

        configureGestures(in: mapView)
    }

    func setPanInteractionActiveForTesting(_ isActive: Bool) {
        setInteractionActive(isActive,
                             source: .mapPan)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        if (gestureRecognizer is NSRotationGestureRecognizer && otherGestureRecognizer is NSMagnificationGestureRecognizer) ||
            (gestureRecognizer is NSMagnificationGestureRecognizer && otherGestureRecognizer is NSRotationGestureRecognizer) {
            return true
        }
        return false
    }

    /// Жесты карты распознаём только над «голой» поверхностью карты. Если событие
    /// попало в интерактивный оверлей-сабвью (debug HUD, attribution badge), уступаем
    /// его этому `NSControl` - иначе gesture recognizer перехватывает `mouseDown` и
    /// кнопки/переключатели панели не нажимаются.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let mapView, let superview = mapView.superview else {
            return true
        }

        let pointInSuperview = superview.convert(event.locationInWindow, from: nil)
        return mapView.hitTest(pointInSuperview) === mapView
    }

    private func configureGestures(in mapView: ImmersiveMapNSView) {
        panGesture.target = self
        panGesture.action = #selector(handlePan(_:))
        panGesture.buttonMask = 0x1
        panGesture.delegate = self
        mapView.addGestureRecognizer(panGesture)

        tiltPanGesture.target = self
        tiltPanGesture.action = #selector(handleTiltPan(_:))
        tiltPanGesture.buttonMask = 0x2
        tiltPanGesture.delegate = self
        mapView.addGestureRecognizer(tiltPanGesture)

        clickGesture.target = self
        clickGesture.action = #selector(handleClick(_:))
        clickGesture.buttonMask = 0x1
        clickGesture.delegate = self
        mapView.addGestureRecognizer(clickGesture)

        rotationGesture.target = self
        rotationGesture.action = #selector(handleRotation(_:))
        rotationGesture.delegate = self
        mapView.addGestureRecognizer(rotationGesture)

        magnificationGesture.target = self
        magnificationGesture.action = #selector(handleMagnification(_:))
        magnificationGesture.delegate = self
        mapView.addGestureRecognizer(magnificationGesture)
    }

    // MARK: - Click

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard let mapView else { return }

        mapView.tapHandler.handleMapTap(at: gesture.location(in: mapView))
    }

    // MARK: - Pan / tilt

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        if gesture.state == .began {
            let isOptionHeld = NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false
            panMode = isOptionHeld ? .tilt : .pan
        }

        switch panMode {
        case .pan:
            applyPan(gesture, in: mapView)
        case .tilt:
            applyTilt(gesture, in: mapView)
        }
    }

    @objc private func handleTiltPan(_ gesture: NSPanGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        applyTilt(gesture, in: mapView)
    }

    private func applyPan(_ gesture: NSPanGestureRecognizer,
                          in mapView: ImmersiveMapNSView) {
        updateInteractionState(for: gesture.state,
                               source: .mapPan)

        let translation = gesture.translation(in: mapView)
        let settings = mapView.cameraRuntime.currentSettings.camera
        mapView.cameraRuntime.panCamera(deltaX: Double(translation.x) * settings.gesturePanTranslationScale,
                                        deltaY: Double(translation.y) * settings.gesturePanTranslationScale)
        gesture.setTranslation(.zero, in: mapView)

        switch gesture.state {
        case .ended:
            mapView.cameraAnimationRuntime.startGlobeCameraPanInertiaIfNeeded(initialVelocity: gesture.velocity(in: mapView))
        case .cancelled, .failed:
            mapView.cameraAnimationRuntime.cancelGlobeCameraPanInertia()
        case .began, .changed, .possible:
            break
        @unknown default:
            mapView.cameraAnimationRuntime.cancelGlobeCameraPanInertia()
        }
    }

    /// Вертикальное перетаскивание меняет pitch (вверх - больше наклона),
    /// горизонтальное - вращает камеру.
    private func applyTilt(_ gesture: NSPanGestureRecognizer,
                           in mapView: ImmersiveMapNSView) {
        updateInteractionState(for: gesture.state,
                               source: .pitchControl)

        let translation = gesture.translation(in: mapView)
        gesture.setTranslation(.zero, in: mapView)
        let bounds = mapView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        if translation.y != 0,
           let currentPitch = mapView.cameraRuntime.currentPitch {
            let maximumPitch = mapView.cameraRuntime.currentMaximumPitch()
            let pitchDelta = -Float(translation.y / bounds.height) * maximumPitch
            mapView.cameraAnimationRuntime.setPitchTarget(currentPitch + pitchDelta)
        }

        if translation.x != 0 {
            let yawDelta = Float(translation.x / bounds.width) * .pi
            mapView.cameraRuntime.rotateCameraYaw(delta: yawDelta)
        }
    }

    // MARK: - Rotation

    @objc private func handleRotation(_ gesture: NSRotationGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        updateInteractionState(for: gesture.state,
                               source: .mapRotation)
        // AppKit считает положительным вращение против часовой (y-вверх);
        // UIKit - по часовой. Инвертируем, чтобы карта вращалась за пальцами.
        let rotation = -gesture.rotation
        let settings = mapView.cameraRuntime.currentSettings.camera
        mapView.cameraRuntime.rotateCameraYaw(delta: Float(rotation) * settings.rotationGestureSensitivity)
        gesture.rotation = 0
    }

    // MARK: - Magnification

    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        updateInteractionState(for: gesture.state,
                               source: .mapPinch)
        let scale = 1.0 + gesture.magnification
        guard scale > 0 else {
            return
        }

        mapView.cameraRuntime.zoomCamera(scale: scale,
                                         velocity: 0)
        gesture.magnification = 0
    }

    // MARK: - Scroll zoom

    func handleScrollWheel(_ event: NSEvent) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        let isTrackpadGesture = event.phase != [] || event.momentumPhase != []
        if isTrackpadGesture {
            if event.phase.contains(.began) {
                setInteractionActive(true,
                                     source: .scrollZoom)
            }
            applyScrollZoom(deltaY: event.scrollingDeltaY,
                            divisor: ScrollZoom.preciseDivisor,
                            in: mapView)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                setInteractionActive(false,
                                     source: .scrollZoom)
            }
            return
        }

        // Дискретное колесо мыши: одиночные события без фаз.
        mapView.cameraAnimationRuntime.cancelAnimations()
        let divisor = event.hasPreciseScrollingDeltas ? ScrollZoom.preciseDivisor : ScrollZoom.lineDivisor
        applyScrollZoom(deltaY: event.scrollingDeltaY,
                        divisor: divisor,
                        in: mapView)
    }

    private func applyScrollZoom(deltaY: CGFloat,
                                 divisor: CGFloat,
                                 in mapView: ImmersiveMapNSView) {
        guard deltaY != 0 else {
            return
        }

        // Колесо/скролл «вверх» приближает карту.
        mapView.cameraRuntime.zoomCamera(delta: Double(deltaY / divisor))
    }

    // MARK: - Interaction state

    private func updateInteractionState(for state: NSGestureRecognizer.State,
                                        source: ImmersiveMapInteractionRuntime.Source) {
        switch state {
        case .began, .changed:
            setInteractionActive(true,
                                 source: source)
        case .ended, .cancelled, .failed:
            setInteractionActive(false,
                                 source: source)
        case .possible:
            return
        @unknown default:
            setInteractionActive(false,
                                 source: source)
        }
    }

    private func setInteractionActive(_ isActive: Bool,
                                      source: ImmersiveMapInteractionRuntime.Source) {
        guard let mapView else { return }

        if isActive {
            mapView.cameraAnimationRuntime.cancelAnimations()
        }

        mapView.interactionRuntime.setActive(isActive,
                                             source: source,
                                             notifiesUserInteractionBegan: true)
    }
}

#endif
