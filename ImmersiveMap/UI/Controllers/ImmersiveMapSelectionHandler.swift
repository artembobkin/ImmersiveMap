// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Holds the map's selection state and applies `ImmersiveMapSelectionController` commands.
/// Responsible for hit-testing avatar markers and scene models, select/clear events,
/// delivering tap events, and syncing the selected object with the available map objects.
@MainActor
final class ImmersiveMapSelectionHandler {
    enum MapTapResult {
        case consumed
        case background
    }

    private let avatarRuntime: ImmersiveMapAvatarRuntime
    private let sceneModelRuntime: ImmersiveMapSceneModelRuntime
    private let viewportRuntime: ImmersiveMapViewportRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime
    private weak var selectionController: ImmersiveMapSelectionController?
    private var currentSelection: ImmersiveMapSelection?
    private var avatarSelectionSnapshot: AvatarSelectionSnapshot = .empty
    private var sceneModelSelectionSnapshot: SceneModelSelectionSnapshot = .empty

    /// A recreated renderer restarts frame indices at zero; the monotonic
    /// guards in the snapshot setters would reject every snapshot it produces
    /// and freeze hit-testing on the previous renderer's layout.
    func resetSelectionSnapshotsForRendererRecreation() {
        avatarSelectionSnapshot = .empty
        sceneModelSelectionSnapshot = .empty
    }
    private var avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?
    private var sceneModelTapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)?

    init(avatarRuntime: ImmersiveMapAvatarRuntime,
         sceneModelRuntime: ImmersiveMapSceneModelRuntime,
         viewportRuntime: ImmersiveMapViewportRuntime,
         renderRuntime: ImmersiveMapRenderRuntime) {
        self.avatarRuntime = avatarRuntime
        self.sceneModelRuntime = sceneModelRuntime
        self.viewportRuntime = viewportRuntime
        self.renderRuntime = renderRuntime
    }

    func syncController(_ newSelectionController: ImmersiveMapSelectionController?) {
        guard selectionController !== newSelectionController else {
            return
        }

        selectionController?.detachHandler(ownedBy: self)
        selectionController = newSelectionController
        newSelectionController?.attachHandler(owner: self) { [weak self] command in
            self?.handle(command) ?? false
        }
        newSelectionController?.updateCurrentSelection(currentSelection)
    }

    func setAvatarTapAction(_ action: ((ImmersiveMapAvatarTapEvent) -> Void)?) {
        avatarTapAction = action
    }

    func setSceneModelTapAction(_ action: ((ImmersiveMapSceneModelTapEvent) -> Void)?) {
        sceneModelTapAction = action
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

    func updateSceneModelSelectionSnapshot(_ snapshot: SceneModelSelectionSnapshot) {
        guard snapshot.frameIndex >= sceneModelSelectionSnapshot.frameIndex else {
            return
        }
        sceneModelSelectionSnapshot = snapshot
    }

    func handleSceneModelControllerDidChange() {
        syncSelectionWithAvailableMapObjects()
        renderRuntime.requestFrame()
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

    /// Avatars are hit-tested before scene models: they are screen-space
    /// overlays drawn on top of the world pass, so an avatar covering a model
    /// takes the tap. An avatar nothing consumes (no tap action, no selection
    /// controller) is not interactive at all, and the model underneath still
    /// gets its chance.
    func handleMapTap(at point: CGPoint) -> MapTapResult {
        if let target = avatarHitTarget(at: point),
           consumeAvatarTap(target: target, at: point) {
            return .consumed
        }

        if let entry = sceneModelHitEntry(at: point),
           consumeSceneModelTap(entry: entry, at: point) {
            return .consumed
        }

        selectionController?.notifyMapBackgroundTap(at: point)
        _ = clear(source: .tap,
                  screenPoint: point)
        return .background
    }

    private func consumeAvatarTap(target: AvatarSelectionTarget,
                                  at point: CGPoint) -> Bool {
        var isConsumed = false
        if let avatarTapAction,
           case .marker(let markerID) = target,
           let marker = avatarRuntime.marker(id: markerID) {
            avatarTapAction(ImmersiveMapAvatarTapEvent(marker: marker,
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
        return isConsumed
    }

    private func consumeSceneModelTap(entry: SceneModelSelectionEntry,
                                      at point: CGPoint) -> Bool {
        var isConsumed = false
        if let sceneModelTapAction,
           let model = sceneModelRuntime.model(id: entry.id) {
            sceneModelTapAction(ImmersiveMapSceneModelTapEvent(model: model,
                                                               coordinate: entry.coordinate,
                                                               screenPoint: point))
            isConsumed = true
        }
        if selectionController != nil {
            let selection = ImmersiveMapSelection(kind: .sceneModel,
                                                  objectID: entry.id)
            if isSelectionAvailable(selection) {
                _ = select(selection,
                           source: .tap,
                           screenPoint: point)
                isConsumed = true
            }
        }
        return isConsumed
    }

    private func avatarHitTarget(at point: CGPoint) -> AvatarSelectionTarget? {
        guard avatarSelectionSnapshot.entries.isEmpty == false,
              avatarSelectionSnapshot.drawSize.height > 0 else {
            return nil
        }

        return avatarSelectionSnapshot.hitTest(point: pixelPoint(from: point,
                                                                 drawSize: avatarSelectionSnapshot.drawSize))
    }

    private func sceneModelHitEntry(at point: CGPoint) -> SceneModelSelectionEntry? {
        guard sceneModelSelectionSnapshot.entries.isEmpty == false,
              sceneModelSelectionSnapshot.drawSize.height > 0 else {
            return nil
        }

        let scale = viewportRuntime.contentsScale
        let drawSize = sceneModelSelectionSnapshot.drawSize
        return sceneModelSelectionSnapshot.hitTest(
            point: pixelPoint(from: point, drawSize: drawSize),
            minimumTouchSizePixels: SceneModelSelectionSnapshot.minimumTouchSizePoints * scale)
    }

    /// View points to drawable pixels with the y axis flipped: the renderer
    /// projects with the origin bottom-left, UIKit and AppKit hand taps over
    /// top-left.
    private func pixelPoint(from point: CGPoint, drawSize: CGSize) -> CGPoint {
        let scale = viewportRuntime.contentsScale
        return CGPoint(x: point.x * scale,
                       y: drawSize.height - point.y * scale)
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
        case .sceneModel:
            return sceneModelRuntime.model(id: selection.objectID) != nil
        }
    }

    private func applySelectionVisualState(for selection: ImmersiveMapSelection,
                                           isSelected: Bool) {
        switch selection.kind {
        case .avatar:
            avatarRuntime.updateMarkerSelection(id: selection.objectID,
                                                isSelected: isSelected)
        case .sceneModel:
            // Scene models carry no selected appearance: the engine draws the
            // asset as authored, and highlighting is the app's to do.
            break
        }
    }
}
