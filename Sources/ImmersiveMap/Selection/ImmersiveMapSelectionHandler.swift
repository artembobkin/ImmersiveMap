// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// The `Selection` folder: what the map has selected and how a tap or the
/// app changes it. The public handle (`ImmersiveMapSelectionController`
/// with its selection and event values), this handler, which holds the
/// state, the protocol a selectable feature implements
/// (`SelectableMapFeature`), and the seam to the map view it serves
/// (`SelectionHost`). It names no feature: what can be picked, whether an
/// object is still there, how a selected one looks and which tap event the
/// app gets are each feature's own, in its `Selection` folder. It knows
/// nothing of `UI` either: no view, no gesture, no runtime of the map view.
///
/// Holds the map's selection state and applies `ImmersiveMapSelectionController` commands.
/// Responsible for asking the features what is under a tap, select/clear events,
/// and syncing the selected object with the objects the features hold.
@MainActor
final class ImmersiveMapSelectionHandler {
    enum MapTapResult {
        case consumed
        case background
    }

    private let host: SelectionHost
    /// The selectable features, in the order a tap asks them.
    private let features: [any SelectableMapFeature]
    private weak var selectionController: ImmersiveMapSelectionController?
    private var currentSelection: ImmersiveMapSelection?

    /// `features` are asked for the object under a tap in the order given,
    /// so a feature drawn over the others comes first.
    init(host: SelectionHost, features: [any SelectableMapFeature]) {
        self.host = host
        self.features = features
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
            setSelected(false, currentSelection)
        }

        setSelected(true, selection)
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

        setSelected(false, currentSelection)
        self.currentSelection = nil
        selectionController?.notifySelectionCleared(
            ImmersiveMapSelectionClearEvent(previousSelection: currentSelection,
                                            source: source,
                                            screenPoint: screenPoint)
        )
        return true
    }

    /// Hands each feature what it drew in a frame that reached the screen.
    func updatePickData(_ pickData: [any SelectionPickData]) {
        for data in pickData {
            feature(of: data.kind)?.updatePickData(data)
        }
    }

    /// A recreated renderer restarts frame indices at zero. The features
    /// drop a frame older than the one they hold, so without this they
    /// would reject everything it draws and freeze hit-testing on the
    /// previous renderer's layout.
    func resetPickDataForRendererRecreation() {
        for feature in features {
            feature.resetPickData()
        }
    }

    /// A feature's objects changed: the selected one may be gone.
    func handleFeatureDidChange() {
        syncSelectionWithAvailableObjects()
        host.requestFrame()
    }

    func syncSelectionWithAvailableObjects() {
        guard let currentSelection else {
            return
        }

        guard isSelectionAvailable(currentSelection) else {
            _ = clear(source: .system,
                      screenPoint: nil)
            return
        }
    }

    /// The features are asked in their order, the ones drawn over the world
    /// first. A hit nothing consumes (no tap action, no selection
    /// controller) is not interactive at all, and the feature underneath
    /// still gets its chance.
    func handleMapTap(at point: CGPoint) -> MapTapResult {
        let contentsScale = host.contentsScale
        for feature in features {
            if let hit = feature.hitTest(at: point, contentsScale: contentsScale),
               consumeTap(hit, of: feature, at: point) {
                return .consumed
            }
        }

        selectionController?.notifyMapBackgroundTap(at: point)
        _ = clear(source: .tap,
                  screenPoint: point)
        return .background
    }

    /// The feature's tap event first, then the selection, as two separate
    /// consumers: a tap on an already selected object still delivers its
    /// event.
    private func consumeTap(_ hit: SelectionHit,
                            of feature: any SelectableMapFeature,
                            at point: CGPoint) -> Bool {
        var isConsumed = feature.deliverTap(hit, at: point)
        if selectionController != nil,
           feature.contains(hit.selection) {
            _ = select(hit.selection,
                       source: .tap,
                       screenPoint: point)
            isConsumed = true
        }
        return isConsumed
    }

    private func feature(of kind: ImmersiveMapSelection.Kind) -> (any SelectableMapFeature)? {
        features.first { $0.owns(kind) }
    }

    private func isSelectionAvailable(_ selection: ImmersiveMapSelection) -> Bool {
        feature(of: selection.kind)?.contains(selection) ?? false
    }

    private func setSelected(_ isSelected: Bool, _ selection: ImmersiveMapSelection) {
        feature(of: selection.kind)?.setSelected(isSelected, selection)
    }
}
