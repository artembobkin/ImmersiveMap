// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  ImmersiveMapSelectionController.swift
//  ImmersiveMap
//

import CoreGraphics
import Foundation

public struct ImmersiveMapSelection: Equatable {
    public enum Kind: String {
        case avatar
    }

    public let kind: Kind
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

/// Public command/callback surface для app-driven map selection.
/// Держит externally visible selection state синхронизированным с attached map view runtime.
@MainActor
public final class ImmersiveMapSelectionController {
    private var selectedSelection: ImmersiveMapSelection?
    private var commandHandler: ((ImmersiveMapSelectionCommand) -> Bool)?

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

    func setCommandHandler(_ handler: ((ImmersiveMapSelectionCommand) -> Bool)?) {
        commandHandler = handler
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
