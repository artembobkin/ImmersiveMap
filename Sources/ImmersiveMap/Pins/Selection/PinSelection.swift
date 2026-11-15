// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

extension ImmersiveMapSelection.Kind {
    /// A pin pin, named by `ImmersiveMapPin.id`.
    public static let pin = ImmersiveMapSelection.Kind(rawValue: "pin")
}

/// The pins a selection can name, and the one drawn as selected: the
/// app's pins as the map view holds them.
@MainActor
protocol PinSelectionSource: AnyObject {
    /// The pin with `id`, nil when the map holds none.
    func pin(id: UInt64) -> ImmersiveMapPin?
    /// Draws the pin as selected, or as it was.
    func updatePinSelection(id: UInt64, isSelected: Bool)
}

/// The pins' side of the selection (`SelectableMapFeature`): a tap is
/// tested against the pins of the last frame on screen
/// (`PinSelectionSnapshot`), and a selected pin is drawn as selected.
@MainActor
final class PinSelection: SelectableMapFeature {
    /// The app's action for a tap on a pin, with or without a selection.
    var tapAction: ((ImmersiveMapPinTapEvent) -> Void)?

    private let source: PinSelectionSource
    private var snapshot: PinSelectionSnapshot = .empty

    init(source: PinSelectionSource) {
        self.source = source
    }

    func owns(_ kind: ImmersiveMapSelection.Kind) -> Bool {
        kind == .pin
    }

    func updatePickData(_ pickData: any SelectionPickData) {
        guard let newSnapshot = pickData as? PinSelectionSnapshot,
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
        guard case .pin(let pinID) = snapshot.hitTest(point: pixelPoint) else {
            return nil
        }
        return SelectionHit(ImmersiveMapSelection(kind: .pin, objectID: pinID))
    }

    func contains(_ selection: ImmersiveMapSelection) -> Bool {
        source.pin(id: selection.objectID) != nil
    }

    func setSelected(_ isSelected: Bool, _ selection: ImmersiveMapSelection) {
        source.updatePinSelection(id: selection.objectID, isSelected: isSelected)
    }

    func deliverTap(_ hit: SelectionHit, at point: CGPoint) -> Bool {
        guard let tapAction,
              let pin = source.pin(id: hit.selection.objectID) else {
            return false
        }
        tapAction(ImmersiveMapPinTapEvent(pin: pin, screenPoint: point))
        return true
    }
}
