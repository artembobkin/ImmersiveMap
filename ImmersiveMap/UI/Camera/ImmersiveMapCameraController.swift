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
    /// Владелец текущей привязки (camera runtime конкретного host view).
    /// Читается и пишется только на main (см. performOnMain).
    private weak var runtimeOwner: AnyObject?

    public var onMapBackgroundTap: (() -> Void)?
    public var onUserInteractionBegan: (() -> Void)?
    public var onCameraPositionChanged: ((ImmersiveMapCameraPosition) -> Void)?
    public var onCameraSnapshotChanged: ((ImmersiveMapCameraSnapshot) -> Void)?

    /// Внутренние подписчики начала пользовательского жеста (например, камера-тур).
    /// Отдельный список, чтобы не конфликтовать с публичным `onUserInteractionBegan`.
    @MainActor private var userInteractionObservers: [UUID: () -> Void] = [:]

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

    /// Привязывает контроллер к runtime карты и реиграет накопленные команды.
    /// `owner` запоминается, чтобы отвязка была строго по владельцу.
    func attachRuntime(owner: AnyObject,
                       commandHandler: @escaping (ImmersiveMapCameraCommand) -> Void) {
        performOnMain {
            self.runtimeOwner = owner
            self.commandHandler = commandHandler
            let commands = self.pendingCommands
            self.pendingCommands.removeAll(keepingCapacity: true)
            commands.forEach(commandHandler)
        }
    }

    /// Отвязывает контроллер только если им всё ещё владеет `owner`.
    /// SwiftUI сначала создаёт новый host view, затем демонтирует старый:
    /// демонтаж старого не должен стирать привязку и кэши, которые уже
    /// установил новый view для того же контроллера.
    func detachRuntime(owner: AnyObject) {
        performOnMain {
            guard self.runtimeOwner === owner else {
                return
            }

            self.runtimeOwner = nil
            self.commandHandler = nil
            self.updateCurrentCameraPosition(nil)
            self.updateCurrentCameraSnapshot(nil)
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

    @MainActor func addUserInteractionObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        userInteractionObservers[token] = observer
        return token
    }

    @MainActor func removeUserInteractionObserver(_ token: UUID) {
        userInteractionObservers[token] = nil
    }

    @MainActor func notifyUserInteractionBegan() {
        onUserInteractionBegan?()
        userInteractionObservers.values.forEach { $0() }
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
