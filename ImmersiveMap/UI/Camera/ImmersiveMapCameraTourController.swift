// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One camera-tour shot: where to fly, with which flight options, and how long
/// to hold the shot after arrival.
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

/// Drives the camera through a predefined sequence of shots, chaining flights
/// via the `fly` completion: cinematic tours, demo flyovers, onboarding.
/// Stops on `stop()` and, by default, when the user takes over control, so
/// flights don't fight with gestures.
@MainActor
public final class ImmersiveMapCameraTourController {
    private let camera: ImmersiveMapCameraController
    private var task: Task<Void, Never>?
    private var interactionObserverToken: UUID?
    private var onFinished: (() -> Void)?
    /// Incremented on every `start` so the tail of a cancelled task can't
    /// finish a tour started after it.
    private var generation = 0

    public init(camera: ImmersiveMapCameraController) {
        self.camera = camera
    }

    public var isRunning: Bool {
        task != nil
    }

    /// Starts the tour, stopping the previous one first.
    /// - Parameters:
    ///   - shots: the sequence of shots, at least one.
    ///   - establish: optional starting position, applied with an instant `jump`.
    ///   - loop: repeat the sequence until explicitly stopped.
    ///   - stopOnUserInteraction: kill the tour when a user gesture begins.
    ///   - onFinished: called exactly once on any tour completion.
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

    /// Wraps the callback-based `fly` in async. No separate cancellation handler
    /// is needed: the only way the task gets cancelled is `stop()`, which kills
    /// the flight via `cancelFlight()`, triggering the completion and resuming
    /// the continuation.
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
