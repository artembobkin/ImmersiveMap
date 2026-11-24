// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

extension ImmersiveMapSelection.Kind {
    /// The tiles of the tile grid: the kind their pick data and a tap's
    /// hit go by. A tile is never the map's single selection
    /// (`ImmersiveMapSelectionController`): the grid keeps a set of its
    /// own, on `ImmersiveMapTileGridController`.
    static let tileGrid = ImmersiveMapSelection.Kind(rawValue: "tileGrid")
}

/// The grid a tap can change: the app's controller as the map view holds
/// it.
@MainActor
protocol TileGridSelectionSource: AnyObject {
    /// The attached controller, nil when the map shows no grid.
    var tileGridController: ImmersiveMapTileGridController? { get }
}

/// The tile grid's side of a tap (`SelectableMapFeature`): the tap is
/// turned into the tile under it, of the zoom the last frame on screen
/// showed (`TileGridSelectionSnapshot`), and the tile is selected or
/// deselected in the app's controller, which holds any number of them.
/// The tap is the gesture the settings name (`tapKind`): a single tap, a
/// double tap, which the grid then takes from the zoom, or a secondary
/// one.
/// The grid lies on the ground under everything else, so it is asked last,
/// and it takes no part in the map's single selection beyond ending it: a
/// tap on a tile is a tap away from the pin or the model that was
/// selected.
@MainActor
final class TileGridSelection: SelectableMapFeature {
    private let source: TileGridSelectionSource
    private var snapshot: TileGridSelectionSnapshot = .empty

    init(source: TileGridSelectionSource) {
        self.source = source
    }

    /// A tile in a selection's object id: five bits of zoom over twice
    /// twenty-nine of x and y, room for every zoom a tile is named at.
    static func objectID(of tile: Tile) -> UInt64 {
        UInt64(tile.z) << 58 | UInt64(tile.x) << 29 | UInt64(tile.y)
    }

    static func tile(ofObjectID id: UInt64) -> Tile {
        let mask: UInt64 = (1 << 29) - 1
        return Tile(x: Int((id >> 29) & mask), y: Int(id & mask), z: Int(id >> 58))
    }

    func owns(_ kind: ImmersiveMapSelection.Kind) -> Bool {
        kind == .tileGrid
    }

    func updatePickData(_ pickData: any SelectionPickData) {
        guard let newSnapshot = pickData as? TileGridSelectionSnapshot,
              newSnapshot.frameIndex >= snapshot.frameIndex else {
            return
        }
        snapshot = newSnapshot
    }

    func resetPickData() {
        snapshot = .empty
    }

    func hitTest(at point: CGPoint, contentsScale: CGFloat) -> SelectionHit? {
        guard source.tileGridController != nil, snapshot.drawSize.height > 0 else { return nil }
        let pixelPoint = SelectionPointMath.pixelPoint(from: point,
                                                       drawSize: snapshot.drawSize,
                                                       contentsScale: contentsScale)
        guard let hit = snapshot.hitTest(point: pixelPoint) else { return nil }
        return SelectionHit(ImmersiveMapSelection(kind: .tileGrid, objectID: Self.objectID(of: hit.tile)),
                            coordinate: hit.coordinate)
    }

    /// Never: a tile is not the map's single selection.
    func contains(_: ImmersiveMapSelection) -> Bool {
        false
    }

    var clearsSelectionOnTap: Bool { true }

    /// The gesture the settings of the frame on screen give the grid.
    var tapKind: MapTapKind {
        switch snapshot.gesture {
        case .tap: .single
        case .doubleTap: .double
        case .secondaryTap: .secondary
        }
    }

    /// While the grid shows tiles a gesture may select, the gesture is the
    /// grid's: a double tap then selects and does not zoom.
    var claimsItsTapKind: Bool {
        source.tileGridController != nil && snapshot.projection != nil
    }

    func deliverTap(_ hit: SelectionHit, at point: CGPoint) -> Bool {
        guard let controller = source.tileGridController, let coordinate = hit.coordinate else { return false }
        let outcome = controller.applyTap(ImmersiveMapTileID(Self.tile(ofObjectID: hit.selection.objectID)),
                                          mode: snapshot.mode,
                                          limit: snapshot.selectionLimit,
                                          selectableBounds: snapshot.selectableBounds,
                                          coordinate: coordinate,
                                          screenPoint: point)
        return outcome != .passed
    }
}
