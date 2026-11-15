// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// A map feature whose objects a tap or the app can select. The one way
/// into the selection: a feature conforms in its own folder
/// (`PinSelection`, `SceneModelSelection`, `LayerSelection`), declares
/// its `ImmersiveMapSelection.Kind` there, and is handed to
/// `ImmersiveMapSelectionHandler`, which names no feature. A new selectable
/// feature is a new conformance and one more entry in the handler's list.
@MainActor
protocol SelectableMapFeature: AnyObject {
    /// Whether a selection of `kind` names an object of this feature. A
    /// feature has one kind, or a kind for each of its groups of objects
    /// (a layer of the app's data).
    func owns(_ kind: ImmersiveMapSelection.Kind) -> Bool

    /// Takes what the feature drew in a frame that reached the screen. Only
    /// data of a kind the feature owns arrives. A frame older than the one
    /// held is dropped, since the frames complete on the GPU out of the
    /// main thread's order.
    func updatePickData(_ pickData: any SelectionPickData)

    /// Forgets what was drawn: a recreated renderer counts its frames from
    /// zero again, and the older-frame check would drop all it draws.
    func resetPickData()

    /// The object under `point` (view points, origin top-left), from what
    /// the feature last drew. `contentsScale` is the drawable's pixels to a
    /// point of the view.
    func hitTest(at point: CGPoint, contentsScale: CGFloat) -> SelectionHit?

    /// Whether the feature still holds the object `selection` names.
    func contains(_ selection: ImmersiveMapSelection) -> Bool

    /// Draws the object as selected, or as it was. A feature with no
    /// selected appearance leaves it empty.
    func setSelected(_ isSelected: Bool, _ selection: ImmersiveMapSelection)

    /// Delivers the feature's own tap event for a hit. True when an action
    /// of the app took it.
    func deliverTap(_ hit: SelectionHit, at point: CGPoint) -> Bool
}

extension SelectableMapFeature {
    func setSelected(_ isSelected: Bool, _ selection: ImmersiveMapSelection) {}
}

/// The object a tap landed on.
struct SelectionHit {
    /// The object, as a selection names it.
    let selection: ImmersiveMapSelection
    /// Where on the map the tap landed on the object, when the feature
    /// knows: the place a model was drawn at, the point of a zone under
    /// the finger.
    let coordinate: GeoCoordinate?

    init(_ selection: ImmersiveMapSelection, coordinate: GeoCoordinate? = nil) {
        self.selection = selection
        self.coordinate = coordinate
    }
}

/// What one feature drew in one frame that a tap can land on. The frame
/// collects these from the features that drew (`FrameContextSharedState`),
/// and the engine hands them on once the frame is on the screen, so a tap
/// is tested against what is visible.
protocol SelectionPickData: Sendable {
    /// A kind the feature the data belongs to owns.
    var kind: ImmersiveMapSelection.Kind { get }
    /// The frame that drew it.
    var frameIndex: UInt64 { get }
}

enum SelectionPointMath {
    /// View points to drawable pixels with the y axis flipped: the renderer
    /// projects with the origin bottom-left, UIKit and AppKit hand taps over
    /// top-left.
    static func pixelPoint(from point: CGPoint, drawSize: CGSize, contentsScale: CGFloat) -> CGPoint {
        CGPoint(x: point.x * contentsScale,
                y: drawSize.height - point.y * contentsScale)
    }
}
