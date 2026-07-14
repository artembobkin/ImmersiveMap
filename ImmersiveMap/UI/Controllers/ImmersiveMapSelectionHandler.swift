// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Хранит selection state карты и применяет команды `ImmersiveMapSelectionController`.
/// Отвечает за hit-testing avatar markers, select/clear события, доставку marker tap
/// событий и синхронизацию выбранного объекта с доступными map objects.
@MainActor
final class ImmersiveMapSelectionHandler {
    enum MapTapResult {
        case consumed
        case background
    }

    private let avatarRuntime: ImmersiveMapAvatarRuntime
    private let viewportRuntime: ImmersiveMapViewportRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime
    private weak var selectionController: ImmersiveMapSelectionController?
    private var currentSelection: ImmersiveMapSelection?
    private var avatarSelectionSnapshot: AvatarSelectionSnapshot = .empty
    private var markerTapAction: ((ImmersiveMapMarkerTapEvent) -> Void)?

    init(avatarRuntime: ImmersiveMapAvatarRuntime,
         viewportRuntime: ImmersiveMapViewportRuntime,
         renderRuntime: ImmersiveMapRenderRuntime) {
        self.avatarRuntime = avatarRuntime
        self.viewportRuntime = viewportRuntime
        self.renderRuntime = renderRuntime
    }

    func syncController(_ newSelectionController: ImmersiveMapSelectionController?) {
        guard selectionController !== newSelectionController else {
            return
        }

        selectionController?.setCommandHandler(nil)
        selectionController?.updateCurrentSelection(nil)
        selectionController = newSelectionController
        newSelectionController?.setCommandHandler { [weak self] command in
            self?.handle(command) ?? false
        }
        newSelectionController?.updateCurrentSelection(currentSelection)
    }

    func setMarkerTapAction(_ action: ((ImmersiveMapMarkerTapEvent) -> Void)?) {
        markerTapAction = action
    }

    func currentMapSelection() -> ImmersiveMapSelection? {
        currentSelection
    }

    @discardableResult
    func handle(_ command: ImmersiveMapSelectionCommand) -> Bool {
        switch command {
        case .select(let selection):
            return select(selection,
                          source: .programmatic,
                          screenPoint: nil)
        case .clear:
            return clear(source: .programmatic,
                         screenPoint: nil)
        }
    }

    @discardableResult
    func select(_ selection: ImmersiveMapSelection,
                source: ImmersiveMapSelectionSource,
                screenPoint: CGPoint?) -> Bool {
        guard isSelectionAvailable(selection) else {
            return false
        }

        if currentSelection == selection {
            return true
        }

        if let currentSelection {
            applySelectionVisualState(for: currentSelection,
                                      isSelected: false)
        }

        applySelectionVisualState(for: selection,
                                  isSelected: true)
        currentSelection = selection
        selectionController?.notifySelectionChanged(
            ImmersiveMapSelectionChangeEvent(selection: selection,
                                             source: source,
                                             screenPoint: screenPoint)
        )
        return true
    }

    @discardableResult
    func clear(source: ImmersiveMapSelectionSource,
               screenPoint: CGPoint?) -> Bool {
        guard let currentSelection else {
            return false
        }

        applySelectionVisualState(for: currentSelection,
                                  isSelected: false)
        self.currentSelection = nil
        selectionController?.notifySelectionCleared(
            ImmersiveMapSelectionClearEvent(previousSelection: currentSelection,
                                            source: source,
                                            screenPoint: screenPoint)
        )
        return true
    }

    func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot) {
        guard snapshot.frameIndex >= avatarSelectionSnapshot.frameIndex else {
            return
        }
        avatarSelectionSnapshot = snapshot
    }

    func handleAvatarControllerDidChange() {
        syncSelectionWithAvailableMapObjects()
        renderRuntime.requestFrame()
    }

    func syncSelectionWithAvailableMapObjects() {
        guard let currentSelection else {
            return
        }

        guard isSelectionAvailable(currentSelection) else {
            _ = clear(source: .system,
                      screenPoint: nil)
            return
        }
    }

    func handleMapTap(at point: CGPoint) -> MapTapResult {
        if let target = avatarHitTarget(at: point) {
            var isConsumed = false
            if let markerTapAction,
               case .marker(let markerID) = target,
               let marker = avatarRuntime.marker(id: markerID) {
                markerTapAction(ImmersiveMapMarkerTapEvent(marker: marker,
                                                           screenPoint: point))
                isConsumed = true
            }
            if selectionController != nil,
               let selection = selection(from: target) {
                _ = select(selection,
                           source: .tap,
                           screenPoint: point)
                isConsumed = true
            }
            if isConsumed {
                return .consumed
            }
        }

        selectionController?.notifyMapBackgroundTap(at: point)
        _ = clear(source: .tap,
                  screenPoint: point)
        return .background
    }

    private func avatarHitTarget(at point: CGPoint) -> AvatarSelectionTarget? {
        guard avatarSelectionSnapshot.entries.isEmpty == false,
              avatarSelectionSnapshot.drawSize.height > 0 else {
            return nil
        }

        let scale = viewportRuntime.contentsScale
        let pixelPoint = CGPoint(x: point.x * scale,
                                 y: avatarSelectionSnapshot.drawSize.height - point.y * scale)
        return avatarSelectionSnapshot.hitTest(point: pixelPoint)
    }

    private func selection(from target: AvatarSelectionTarget?) -> ImmersiveMapSelection? {
        guard case .marker(let avatarID) = target else {
            return nil
        }

        let selection = ImmersiveMapSelection(kind: .avatar,
                                              objectID: avatarID)
        return isSelectionAvailable(selection) ? selection : nil
    }

    private func isSelectionAvailable(_ selection: ImmersiveMapSelection) -> Bool {
        switch selection.kind {
        case .avatar:
            return avatarRuntime.marker(id: selection.objectID) != nil
        }
    }

    private func applySelectionVisualState(for selection: ImmersiveMapSelection,
                                           isSelected: Bool) {
        switch selection.kind {
        case .avatar:
            avatarRuntime.updateMarkerSelection(id: selection.objectID,
                                                isSelected: isSelected)
        }
    }
}
