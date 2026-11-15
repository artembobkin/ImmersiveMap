// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

extension ImmersiveMapSelection.Kind {
    /// A scene model, named by `ImmersiveMapSceneModel.id`.
    public static let sceneModel = ImmersiveMapSelection.Kind(rawValue: "sceneModel")
}

/// The scene models a selection can name: the app's models as the map view
/// holds them.
@MainActor
protocol SceneModelSelectionSource: AnyObject {
    /// The scene model with `id`, nil when the map holds none.
    func model(id: UInt64) -> ImmersiveMapSceneModel?
}

/// The scene models' side of the selection (`SelectableMapFeature`): a tap
/// is tested against the models of the last frame on screen
/// (`SceneModelSelectionSnapshot`). A model carries no selected appearance:
/// the engine draws the asset as authored, and highlighting is the app's to
/// do.
@MainActor
final class SceneModelSelection: SelectableMapFeature {
    /// The app's action for a tap on a model, with or without a selection.
    var tapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)?

    private let source: SceneModelSelectionSource
    private var snapshot: SceneModelSelectionSnapshot = .empty

    init(source: SceneModelSelectionSource) {
        self.source = source
    }

    func owns(_ kind: ImmersiveMapSelection.Kind) -> Bool {
        kind == .sceneModel
    }

    func updatePickData(_ pickData: any SelectionPickData) {
        guard let newSnapshot = pickData as? SceneModelSelectionSnapshot,
              newSnapshot.frameIndex >= snapshot.frameIndex else {
            return
        }
        snapshot = newSnapshot
    }

    func resetPickData() {
        snapshot = .empty
    }

    func hitTest(at point: CGPoint, contentsScale: CGFloat) -> SelectionHit? {
        guard snapshot.entries.isEmpty == false,
              snapshot.drawSize.height > 0 else {
            return nil
        }

        let pixelPoint = SelectionPointMath.pixelPoint(from: point,
                                                       drawSize: snapshot.drawSize,
                                                       contentsScale: contentsScale)
        guard let entry = snapshot.hitTest(
            point: pixelPoint,
            minimumTouchSizePixels: SceneModelSelectionSnapshot.minimumTouchSizePoints * contentsScale) else {
            return nil
        }
        return SelectionHit(ImmersiveMapSelection(kind: .sceneModel, objectID: entry.id), coordinate: entry.coordinate)
    }

    func contains(_ selection: ImmersiveMapSelection) -> Bool {
        source.model(id: selection.objectID) != nil
    }

    func deliverTap(_ hit: SelectionHit, at point: CGPoint) -> Bool {
        guard let tapAction,
              let coordinate = hit.coordinate,
              let model = source.model(id: hit.selection.objectID) else {
            return false
        }
        tapAction(ImmersiveMapSceneModelTapEvent(model: model,
                                                 coordinate: coordinate,
                                                 screenPoint: point))
        return true
    }
}
