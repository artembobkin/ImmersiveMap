// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

extension ImmersiveMapSelection.Kind {
    /// An avatar marker, named by `AvatarMarker.id`.
    public static let avatar = ImmersiveMapSelection.Kind(rawValue: "avatar")
}

/// The avatars a selection can name, and the one drawn as selected: the
/// app's avatars as the map view holds them.
@MainActor
protocol AvatarSelectionSource: AnyObject {
    /// The avatar with `id`, nil when the map holds none.
    func marker(id: UInt64) -> AvatarMarker?
    /// Draws the avatar as selected, or as it was.
    func updateMarkerSelection(id: UInt64, isSelected: Bool)
}

/// The avatars' side of the selection (`SelectableMapFeature`): a tap is
/// tested against the markers of the last frame on screen
/// (`AvatarSelectionSnapshot`), and a selected marker is drawn as selected.
@MainActor
final class AvatarSelection: SelectableMapFeature {
    /// The app's action for a tap on an avatar, with or without a selection.
    var tapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?

    private let source: AvatarSelectionSource
    private var snapshot: AvatarSelectionSnapshot = .empty

    init(source: AvatarSelectionSource) {
        self.source = source
    }

    func owns(_ kind: ImmersiveMapSelection.Kind) -> Bool {
        kind == .avatar
    }

    func updatePickData(_ pickData: any SelectionPickData) {
        guard let newSnapshot = pickData as? AvatarSelectionSnapshot,
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
        guard case .marker(let markerID) = snapshot.hitTest(point: pixelPoint) else {
            return nil
        }
        return SelectionHit(ImmersiveMapSelection(kind: .avatar, objectID: markerID))
    }

    func contains(_ selection: ImmersiveMapSelection) -> Bool {
        source.marker(id: selection.objectID) != nil
    }

    func setSelected(_ isSelected: Bool, _ selection: ImmersiveMapSelection) {
        source.updateMarkerSelection(id: selection.objectID, isSelected: isSelected)
    }

    func deliverTap(_ hit: SelectionHit, at point: CGPoint) -> Bool {
        guard let tapAction,
              let marker = source.marker(id: hit.selection.objectID) else {
            return false
        }
        tapAction(ImmersiveMapAvatarTapEvent(marker: marker, screenPoint: point))
        return true
    }
}
