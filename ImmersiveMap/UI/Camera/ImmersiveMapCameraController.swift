// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

enum ImmersiveMapCameraCommand {
    case jump(ImmersiveMapCameraPosition)
    case fly(ImmersiveMapCameraPosition, CameraFlightOptions, ((Bool) -> Void)?)
    case cancelFlight
    case setAngleTarget(bearing: Float, pitch: Float)
}

/// Public command/callback surface для app-driven camera control.
/// Копит команды до подключения к view и хранит latest camera position для callers.
public final class ImmersiveMapCameraController {
    private let lock = NSLock()
    private var currentPosition: ImmersiveMapCameraPosition?
    private var currentSnapshot: ImmersiveMapCameraSnapshot?
    private var pendingCommands: [ImmersiveMapCameraCommand] = []
    private var commandHandler: ((ImmersiveMapCameraCommand) -> Void)?

    public var onMapBackgroundTap: (() -> Void)?
    public var onUserInteractionBegan: (() -> Void)?
    public var onCameraPositionChanged: ((ImmersiveMapCameraPosition) -> Void)?
    public var onCameraSnapshotChanged: ((ImmersiveMapCameraSnapshot) -> Void)?

    public init() {}

    public func jump(to position: ImmersiveMapCameraPosition) {
        updateCurrentCameraPosition(position)
        enqueue(.jump(position))
    }

    public func fly(to position: ImmersiveMapCameraPosition,
                    options: CameraFlightOptions = .default,
                    completion: ((Bool) -> Void)? = nil) {
        enqueue(.fly(position, options, completion))
    }

    public func cancelFlight() {
        enqueue(.cancelFlight)
    }

    /// Плавно ведет углы камеры (bearing/pitch, в радианах) к цели — для интерактивных контролов.
    /// В отличие от `jump`, фактические углы подводятся к цели покадрово (сглаживание).
    func setCameraAngleTarget(bearingRadians: Float, pitchRadians: Float) {
        enqueue(.setAngleTarget(bearing: bearingRadians, pitch: pitchRadians))
    }

    public func currentCameraPosition() -> ImmersiveMapCameraPosition? {
        lock.lock()
        defer { lock.unlock() }
        return currentPosition
    }

    public func currentCameraSnapshot() -> ImmersiveMapCameraSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return currentSnapshot
    }

    func setCommandHandler(_ handler: ((ImmersiveMapCameraCommand) -> Void)?) {
        performOnMain {
            self.commandHandler = handler
            guard let handler else {
                return
            }

            let commands = self.pendingCommands
            self.pendingCommands.removeAll(keepingCapacity: true)
            commands.forEach(handler)
        }
    }

    func updateCurrentCameraPosition(_ position: ImmersiveMapCameraPosition?) {
        lock.lock()
        currentPosition = position
        lock.unlock()
    }

    func updateCurrentCameraSnapshot(_ snapshot: ImmersiveMapCameraSnapshot?) {
        lock.lock()
        currentSnapshot = snapshot
        lock.unlock()
    }

    private func enqueue(_ command: ImmersiveMapCameraCommand) {
        performOnMain {
            guard let commandHandler = self.commandHandler else {
                self.pendingCommands.append(command)
                return
            }

            commandHandler(command)
        }
    }

    func notifyMapBackgroundTap() {
        onMapBackgroundTap?()
    }

    func notifyUserInteractionBegan() {
        onUserInteractionBegan?()
    }

    func notifyCameraPositionChanged(_ position: ImmersiveMapCameraPosition) {
        updateCurrentCameraPosition(position)
        onCameraPositionChanged?(position)
    }

    func notifyCameraSnapshotChanged(_ snapshot: ImmersiveMapCameraSnapshot) {
        updateCurrentCameraSnapshot(snapshot)
        onCameraSnapshotChanged?(snapshot)
    }
}
