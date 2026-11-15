// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

extension ImmersiveMapSelection.Kind {
    /// A shape of the layer with `id` (`ImmersiveMapLayer.id`), named by
    /// the shape's id within the layer's source:
    ///
    ///     ImmersiveMapSelection(kind: .layer("zones"), objectID: 42)
    public static func layer(_ id: String) -> ImmersiveMapSelection.Kind {
        ImmersiveMapSelection.Kind(rawValue: layerPrefix + id)
    }

    /// The id of the layer a selection of this kind names a shape of, nil
    /// for the kind of another feature.
    public var layerID: String? {
        rawValue.hasPrefix(Self.layerPrefix) ? String(rawValue.dropFirst(Self.layerPrefix.count)) : nil
    }

    /// The layers as a whole: the kind their pick data goes by.
    static let layers = ImmersiveMapSelection.Kind(rawValue: "layer")
    private static let layerPrefix = "layer:"
}

/// The layers a selection can name a shape of: the app's layers as the map
/// view holds them.
@MainActor
protocol LayerSelectionSource: AnyObject {
    /// The layer with `id`, nil when the map holds none.
    func layer(id: String) -> ImmersiveMapLayer?
}

/// The layers' side of the selection (`SelectableMapFeature`): a tap is
/// tested against the shapes of the layers the last frame on screen drew
/// (`LayerSelectionSnapshot`). A selection stands while the map holds the
/// shape's layer. A shape carries no selected appearance: an app that
/// wants one draws it, as a layer over the selected shape.
@MainActor
final class LayerSelection: SelectableMapFeature {
    /// The app's action for a tap on a shape, with or without a selection.
    var tapAction: ((ImmersiveMapLayerTapEvent) -> Void)?

    private let source: LayerSelectionSource
    private var snapshot: LayerSelectionSnapshot = .empty

    init(source: LayerSelectionSource) {
        self.source = source
    }

    func owns(_ kind: ImmersiveMapSelection.Kind) -> Bool {
        kind == .layers || kind.layerID != nil
    }

    func updatePickData(_ pickData: any SelectionPickData) {
        guard let newSnapshot = pickData as? LayerSelectionSnapshot,
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
        guard let hit = snapshot.hitTest(point: pixelPoint, pixelsPerPoint: contentsScale) else {
            return nil
        }
        return SelectionHit(ImmersiveMapSelection(kind: .layer(hit.layerID), objectID: hit.shapeID),
                            coordinate: hit.coordinate)
    }

    func contains(_ selection: ImmersiveMapSelection) -> Bool {
        guard let layerID = selection.kind.layerID else { return false }
        return source.layer(id: layerID) != nil
    }

    func deliverTap(_ hit: SelectionHit, at point: CGPoint) -> Bool {
        guard let tapAction,
              let coordinate = hit.coordinate,
              let layerID = hit.selection.kind.layerID,
              let layer = source.layer(id: layerID) else {
            return false
        }
        tapAction(ImmersiveMapLayerTapEvent(layer: layer,
                                            shapeID: hit.selection.objectID,
                                            coordinate: coordinate,
                                            screenPoint: point))
        return true
    }
}
