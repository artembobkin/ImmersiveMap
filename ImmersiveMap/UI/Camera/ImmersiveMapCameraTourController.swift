// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Один кадр камера-тура: куда лететь, с какими опциями перелёта и сколько
/// удерживать кадр после прилёта.
public struct ImmersiveMapCameraTourShot: Sendable, Equatable {
    public let position: ImmersiveMapCameraPosition
    public let options: CameraFlightOptions
    public let holdAfter: TimeInterval

    public init(position: ImmersiveMapCameraPosition,
                options: CameraFlightOptions = .default,
                holdAfter: TimeInterval = 0) {
        self.position = position
        self.options = options
        self.holdAfter = holdAfter
    }
}

/// Прогоняет камеру по заранее заданной последовательности кадров, сцепляя
/// перелёты через completion `fly`: кино-туры, демо-облёты, onboarding.
/// Останавливается по `stop()` и, по умолчанию, когда пользователь берёт
/// управление на себя, чтобы перелёты не боролись с жестами.
@MainActor
public final class ImmersiveMapCameraTourController {
    private let camera: ImmersiveMapCameraController
    private var task: Task<Void, Never>?
    private var interactionObserverToken: UUID?
    private var onFinished: (() -> Void)?
    /// Растёт при каждом `start`, чтобы хвост отменённой задачи не завершил
    /// тур, запущенный после неё.
    private var generation = 0

    public init(camera: ImmersiveMapCameraController) {
        self.camera = camera
    }

    public var isRunning: Bool {
        task != nil
    }

    /// Запускает тур, предварительно остановив предыдущий.
    /// - Parameters:
    ///   - shots: последовательность кадров, минимум один.
    ///   - establish: опциональная стартовая позиция, применяется мгновенным `jump`.
    ///   - loop: повторять последовательность до явной остановки.
    ///   - stopOnUserInteraction: гасить тур при начале пользовательского жеста.
    ///   - onFinished: вызывается один раз при любом завершении тура.
    public func start(shots: [ImmersiveMapCameraTourShot],
                      establish: ImmersiveMapCameraPosition? = nil,
                      loop: Bool = false,
                      stopOnUserInteraction: Bool = true,
                      onFinished: (() -> Void)? = nil) {
        stop()
        guard shots.isEmpty == false else {
            onFinished?()
            return
        }

        self.onFinished = onFinished
        if stopOnUserInteraction {
            interactionObserverToken = camera.addUserInteractionObserver { [weak self] in
                self?.stop()
            }
        }

        if let establish {
            camera.jump(to: establish)
        }

        generation += 1
        let startedGeneration = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                for shot in shots {
                    if Task.isCancelled { break }
                    await self.fly(to: shot.position, options: shot.options)
                    if Task.isCancelled { break }
                    if shot.holdAfter > 0 {
                        try? await Task.sleep(for: .seconds(shot.holdAfter))
                    }
                }
            } while loop && Task.isCancelled == false
            guard self.generation == startedGeneration else {
                return
            }
            self.task = nil
            self.finish()
        }
    }

    public func stop() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        camera.cancelFlight()
        finish()
    }

    private func finish() {
        if let interactionObserverToken {
            camera.removeUserInteractionObserver(interactionObserverToken)
            self.interactionObserverToken = nil
        }

        let onFinished = self.onFinished
        self.onFinished = nil
        onFinished?()
    }

    /// Оборачивает callback-based `fly` в async. Отдельный обработчик отмены не
    /// нужен: единственный путь отмены задачи это `stop()`, а он гасит перелёт
    /// через `cancelFlight()`, что триггерит completion и снимает continuation.
    private func fly(to position: ImmersiveMapCameraPosition,
                     options: CameraFlightOptions) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            camera.fly(to: position, options: options) { _ in
                guard resumed == false else { return }
                resumed = true
                continuation.resume()
            }
        }
    }
}
