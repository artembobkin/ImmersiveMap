// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// The `TileGrid` folder: the grid of XYZ tiles an app's user picks tiles
/// on. Everything of the feature is here: the app's handle (this
/// controller and its events), which tiles a frame shows (`TileGridZoom`,
/// `TileGridCoverage`), their texts (`TileGridLabels`), the drawing
/// (`TileGridPipeline`, `TileGridRenderSubsystem`, `Shaders/`) and the tap
/// (`Selection/`). The grid names squares of the ground, not the map's own
/// tiles: nothing here reads the tile store, the planner or the archive,
/// and no other feature reads the grid. No views and no gestures: the map
/// view's side is `UI/Runtime/ImmersiveMapTileGridRuntime`.
///
/// The app's handle on the tile grid: the tiles that are selected, the
/// events, and the text of a tile. Attach it with
/// `ImmersiveMapView.tileGrid(_:)`, which also shows the grid:
///
///     @State private var grid = ImmersiveMapTileGridController()
///
///     ImmersiveMapView()
///         .tileGrid(grid)
///         .tileGridSettings(zoomRange: 15...15)
///         .onAppear {
///             grid.onSelectionChanged = { change in
///                 print(change.selectedTiles)
///             }
///         }
///
/// A tap on a tile selects it, a second tap deselects it, and any number of
/// tiles can be selected at once. The app reads the set at any time
/// (`selectedTiles`) and can change it from code. What the grid shows and
/// what a tap may select are settings
/// (`ImmersiveMapSettings.TileGridSettings`): the limit and the selectable
/// area there govern the taps alone, and a change made from code is applied
/// as given.
///
/// Thread-safe (`@unchecked Sendable`): all mutable state is serialized by
/// `lock`, so the selection can be read and changed from any thread. The
/// callbacks are called on the main thread.
public final class ImmersiveMapTileGridController: @unchecked Sendable {
    private let lock = NSLock()
    private var selected: Set<ImmersiveMapTileID>
    private var labelRevision: UInt64 = 0
    private var selectionChangedHandler: (@Sendable (ImmersiveMapTileGridSelectionChange) -> Void)?
    private var tapRejectedHandler: (@Sendable (ImmersiveMapTileGridTapRejection) -> Void)?
    private var labelProviderHandler: (@Sendable (ImmersiveMapTileID) -> String?)?
    private var changeHandler: (() -> Void)?
    private weak var changeHandlerOwner: AnyObject?

    public init(selectedTiles: Set<ImmersiveMapTileID> = []) {
        selected = selectedTiles
    }

    // MARK: - The selection

    /// The selected tiles as they are now, of every zoom.
    public var selectedTiles: Set<ImmersiveMapTileID> {
        lock.withLock { selected }
    }

    public func isSelected(_ tile: ImmersiveMapTileID) -> Bool {
        lock.withLock { selected.contains(tile) }
    }

    public func select(_ tile: ImmersiveMapTileID) {
        mutate(source: .programmatic) { $0.insert(tile) }
    }

    public func select(_ tiles: some Sequence<ImmersiveMapTileID>) {
        mutate(source: .programmatic) { $0.formUnion(tiles) }
    }

    public func deselect(_ tile: ImmersiveMapTileID) {
        mutate(source: .programmatic) { $0.remove(tile) }
    }

    public func deselect(_ tiles: some Sequence<ImmersiveMapTileID>) {
        mutate(source: .programmatic) { $0.subtract(tiles) }
    }

    /// Selects a tile that is not selected and deselects one that is.
    /// Returns whether the tile is selected afterwards.
    @discardableResult
    public func toggle(_ tile: ImmersiveMapTileID) -> Bool {
        var isSelected = false
        mutate(source: .programmatic) { selected in
            if selected.remove(tile) == nil {
                selected.insert(tile)
                isSelected = true
            }
        }
        return isSelected
    }

    /// Replaces the selection with `tiles`.
    public func setSelectedTiles(_ tiles: Set<ImmersiveMapTileID>) {
        mutate(source: .programmatic) { $0 = tiles }
    }

    public func clearSelection() {
        mutate(source: .programmatic) { $0.removeAll() }
    }

    // MARK: - The events

    /// Called on the main thread after every change of the selection, by a
    /// tap or from code, with what changed. A call that leaves the
    /// selection as it was reports nothing.
    public var onSelectionChanged: (@Sendable (ImmersiveMapTileGridSelectionChange) -> Void)? {
        get { lock.withLock { selectionChangedHandler } }
        set { lock.withLock { selectionChangedHandler = newValue } }
    }

    /// Called on the main thread when a tap on a tile selects nothing: the
    /// limit is reached, or the tile is outside the selectable area.
    public var onTapRejected: (@Sendable (ImmersiveMapTileGridTapRejection) -> Void)? {
        get { lock.withLock { tapRejectedHandler } }
        set { lock.withLock { tapRejectedHandler = newValue } }
    }

    // MARK: - The texts

    /// The text written inside a tile, in place of
    /// `TileGridSettings.labelFormat`: a name the app has for the tile, a
    /// count, a status. Nil from the closure leaves the tile without text.
    /// The text is one line, of the characters the map's labels are
    /// written with. Called on the main thread, for the tiles in view, and
    /// the answer is kept until `reloadLabels()`.
    public var labelProvider: (@Sendable (ImmersiveMapTileID) -> String?)? {
        get { lock.withLock { labelProviderHandler } }
        set {
            lock.lock()
            labelProviderHandler = newValue
            labelRevision &+= 1
            let changeHandler = changeHandler
            lock.unlock()
            changeHandler?()
        }
    }

    /// Asks `labelProvider` again for every tile. Call it when what the
    /// provider answers has changed.
    public func reloadLabels() {
        lock.lock()
        labelRevision &+= 1
        let changeHandler = changeHandler
        lock.unlock()
        changeHandler?()
    }

    // MARK: - The map view's side

    /// What a frame draws of the controller.
    var content: TileGridContent {
        lock.withLock {
            TileGridContent(selectedTiles: selected, labelRevision: labelRevision, labelProvider: labelProviderHandler)
        }
    }

    /// What a tap on a tile came to.
    enum TapOutcome: Equatable {
        /// The tile was selected or deselected.
        case toggled
        /// The tap selected nothing and is spent.
        case rejected
        /// The tap selected nothing and is not the grid's: it goes on as a
        /// tap on the map.
        case passed
    }

    /// A tap on `tile`, under the limit and the area a tap is held to,
    /// and in the mode the settings give: many tiles, or one, which a tap
    /// on another tile moves. A
    /// selected tile is always deselected: neither rule keeps a user from
    /// taking a tile back. On the main thread.
    func applyTap(_ tile: ImmersiveMapTileID,
                  mode: ImmersiveMapSettings.TileGridSettings.SelectionMode = .multiple,
                  limit: Int?,
                  selectableBounds: ImmersiveMapGeoBounds?,
                  coordinate: GeoCoordinate,
                  screenPoint: CGPoint) -> TapOutcome {
        lock.lock()
        let isSelected = selected.contains(tile)
        let count = selected.count
        let rejected = tapRejectedHandler
        lock.unlock()

        if isSelected == false {
            var reason: ImmersiveMapTileGridTapRejection.Reason?
            if let selectableBounds, selectableBounds.overlaps(tile.bounds) == false {
                reason = .outsideSelectableBounds
            } else if mode == .multiple, let limit, count >= limit {
                reason = .limitReached(limit: limit)
            }
            if let reason {
                rejected?(ImmersiveMapTileGridTapRejection(tile: tile, reason: reason,
                                                           coordinate: coordinate, screenPoint: screenPoint))
                return reason == .outsideSelectableBounds ? .passed : .rejected
            }
        }
        mutate(source: .tap) { selected in
            if selected.remove(tile) == nil {
                // One tile at a time: the selection moves to this one.
                if mode == .single { selected.removeAll() }
                selected.insert(tile)
            }
        }
        return .toggled
    }

    func setChangeHandler(_ handler: (() -> Void)?, owner: AnyObject) {
        lock.lock()
        changeHandler = handler
        changeHandlerOwner = owner
        lock.unlock()
    }

    /// Clears the handler only if `owner` still owns it: tearing down an old
    /// host view must not detach the controller from a new view that has
    /// already rebound it to itself.
    func clearChangeHandler(ownedBy owner: AnyObject) {
        lock.lock()
        if changeHandlerOwner === owner {
            changeHandler = nil
            changeHandlerOwner = nil
        }
        lock.unlock()
    }

    /// Applies `change`, and when it left the selection other than it was
    /// asks the map for a frame and reports it on the main thread.
    private func mutate(source: ImmersiveMapSelectionSource, _ change: (inout Set<ImmersiveMapTileID>) -> Void) {
        lock.lock()
        let before = selected
        change(&selected)
        let after = selected
        let changeHandler = changeHandler
        let report = selectionChangedHandler
        lock.unlock()

        guard after != before else { return }
        changeHandler?()
        guard let report else { return }
        let event = ImmersiveMapTileGridSelectionChange(selectedTiles: after,
                                                        added: after.subtracting(before),
                                                        removed: before.subtracting(after),
                                                        source: source)
        if Thread.isMainThread {
            report(event)
        } else {
            DispatchQueue.main.async { report(event) }
        }
    }
}
