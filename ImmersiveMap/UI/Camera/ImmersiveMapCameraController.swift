// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

enum ImmersiveMapCameraCommand {
    case jump(ImmersiveMapCameraPosition)
    case fly(ImmersiveMapCameraPosition, CameraFlightOptions, ((Bool) -> Void)?)
    case cancelFlight
    case setAngleTarget(bearing: Float, pitch: Float)
}

/// Public command/callback surface for app-driven camera control.
/// Accumulates commands until attached to a view and keeps the latest camera position for callers.
public final class ImmersiveMapCameraController {
    private let lock = NSLock()
    private var currentPosition: ImmersiveMapCameraPosition?
    private var currentSnapshot: ImmersiveMapCameraSnapshot?
    private var pendingCommands: [ImmersiveMapCameraCommand] = []
    private var commandHandler: ((ImmersiveMapCameraCommand) -> Void)?
    /// Owner of the current attachment (the camera runtime of a specific host view).
    /// Read and written only on main (see performOnMain).
    private weak var runtimeOwner: AnyObject?

    public var onMapBackgroundTap: (() -> Void)?
    public var onUserInteractionBegan: (() -> Void)?
    public var onCameraPositionChanged: ((ImmersiveMapCameraPosition) -> Void)?
    public var onCameraSnapshotChanged: ((ImmersiveMapCameraSnapshot) -> Void)?

    /// Internal subscribers to the start of a user gesture (e.g. the camera tour).
    /// A separate list so as not to conflict with the public `onUserInteractionBegan`.
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

    /// Smoothly steers the camera angles (bearing/pitch, in radians) toward the target, for interactive controls.
    /// Unlike `jump`, the actual angles approach the target frame by frame (smoothing).
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

    /// Attaches the controller to the map runtime and replays the accumulated commands.
    /// `owner` is remembered so detaching is strictly owner-scoped.
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

    /// Detaches the controller only if `owner` still owns it.
    /// SwiftUI first creates the new host view and then dismantles the old one:
    /// dismantling the old view must not wipe the attachment and caches that
    /// the new view has already installed for the same controller.
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
