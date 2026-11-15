// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  ImmersiveMapSelectionController.swift
//  ImmersiveMap
//

import CoreGraphics
import Foundation

/// An object of the map the app or a tap selected: the feature it belongs
/// to and its id within that feature.
public struct ImmersiveMapSelection: Hashable, Sendable {
    /// The feature a selected object belongs to. An open set: each
    /// selectable feature declares its own value (`.pin`, `.sceneModel`),
    /// so a `switch` over a kind needs a `default`.
    public struct Kind: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public let kind: Kind
    /// The object's id within its feature, such as `ImmersiveMapPin.id`.
    public let objectID: UInt64

    public init(kind: Kind, objectID: UInt64) {
        self.kind = kind
        self.objectID = objectID
    }
}

public enum ImmersiveMapSelectionSource: String {
    case tap
    case programmatic
    case system
}

public struct ImmersiveMapSelectionChangeEvent: Equatable {
    public let selection: ImmersiveMapSelection
    public let source: ImmersiveMapSelectionSource
    public let screenPoint: CGPoint?

    public init(selection: ImmersiveMapSelection,
                source: ImmersiveMapSelectionSource,
                screenPoint: CGPoint?) {
        self.selection = selection
        self.source = source
        self.screenPoint = screenPoint
    }
}

public struct ImmersiveMapSelectionClearEvent: Equatable {
    public let previousSelection: ImmersiveMapSelection
    public let source: ImmersiveMapSelectionSource
    public let screenPoint: CGPoint?

    public init(previousSelection: ImmersiveMapSelection,
                source: ImmersiveMapSelectionSource,
                screenPoint: CGPoint?) {
        self.previousSelection = previousSelection
        self.source = source
        self.screenPoint = screenPoint
    }
}

enum ImmersiveMapSelectionCommand {
    case select(ImmersiveMapSelection)
    case clear
}

/// Public command/callback surface for app-driven map selection.
/// Keeps the externally visible selection state in sync with the attached map view runtime.
@MainActor
public final class ImmersiveMapSelectionController {
    private var selectedSelection: ImmersiveMapSelection?
    private var commandHandler: ((ImmersiveMapSelectionCommand) -> Bool)?
    /// Owner of the current binding (the selection handler of a specific host view).
    private weak var handlerOwner: AnyObject?

    public var onSelectionChanged: ((ImmersiveMapSelectionChangeEvent) -> Void)?
    public var onSelectionCleared: ((ImmersiveMapSelectionClearEvent) -> Void)?
    public var onMapBackgroundTap: ((CGPoint) -> Void)?

    public init() {}

    public func currentSelection() -> ImmersiveMapSelection? {
        selectedSelection
    }

    @discardableResult
    public func select(_ selection: ImmersiveMapSelection) -> Bool {
        commandHandler?(.select(selection)) ?? false
    }

    @discardableResult
    public func clearSelection() -> Bool {
        commandHandler?(.clear) ?? false
    }

    func attachHandler(owner: AnyObject,
                       _ handler: @escaping (ImmersiveMapSelectionCommand) -> Bool) {
        handlerOwner = owner
        commandHandler = handler
    }

    /// Detach strictly by owner: tearing down an old host view must not
    /// erase the binding and selection cache installed by the new view.
    func detachHandler(ownedBy owner: AnyObject) {
        guard handlerOwner === owner else {
            return
        }

        handlerOwner = nil
        commandHandler = nil
        updateCurrentSelection(nil)
    }

    func updateCurrentSelection(_ selection: ImmersiveMapSelection?) {
        selectedSelection = selection
    }

    func notifySelectionChanged(_ event: ImmersiveMapSelectionChangeEvent) {
        selectedSelection = event.selection
        onSelectionChanged?(event)
    }

    func notifySelectionCleared(_ event: ImmersiveMapSelectionClearEvent) {
        selectedSelection = nil
        onSelectionCleared?(event)
    }

    func notifyMapBackgroundTap(at point: CGPoint) {
        onMapBackgroundTap?(point)
    }
}
