// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The app's handle on the tile grid: the selected set, the events, and a
/// tap under the limit and the selectable area.
@MainActor
final class ImmersiveMapTileGridControllerTests: XCTestCase {
    /// What the controller's callbacks, which are `@Sendable`, write to.
    private final class Recorder<Value>: @unchecked Sendable {
        var values: [Value] = []
    }

    private let a = ImmersiveMapTileID(zoom: 15, x: 9647, y: 12320)
    private let b = ImmersiveMapTileID(zoom: 15, x: 9648, y: 12320)
    private let c = ImmersiveMapTileID(zoom: 14, x: 4823, y: 6160)
    private let place = GeoCoordinate(latitude: 40.7, longitude: -74)

    func testTheSetIsChangedFromCode() {
        let controller = ImmersiveMapTileGridController(selectedTiles: [a])
        controller.select([b, c])
        XCTAssertEqual(controller.selectedTiles, [a, b, c])
        controller.deselect(a)
        XCTAssertFalse(controller.isSelected(a))
        XCTAssertFalse(controller.toggle(b))
        XCTAssertTrue(controller.toggle(b))
        controller.setSelectedTiles([c])
        XCTAssertEqual(controller.selectedTiles, [c])
        controller.clearSelection()
        XCTAssertTrue(controller.selectedTiles.isEmpty)
    }

    func testAChangeIsReportedWithWhatChanged() {
        let controller = ImmersiveMapTileGridController(selectedTiles: [a])
        let changes = Recorder<ImmersiveMapTileGridSelectionChange>()
        controller.onSelectionChanged = { changes.values.append($0) }

        controller.setSelectedTiles([b, c])
        XCTAssertEqual(changes.values.count, 1)
        XCTAssertEqual(changes.values.last?.selectedTiles, [b, c])
        XCTAssertEqual(changes.values.last?.added, [b, c])
        XCTAssertEqual(changes.values.last?.removed, [a])
        XCTAssertEqual(changes.values.last?.source, .programmatic)

        controller.select(b)
        controller.deselect(a)
        XCTAssertEqual(changes.values.count, 1, "A call that changes nothing reports nothing")
    }

    func testOnlyAChangeAsksForAFrame() {
        let controller = ImmersiveMapTileGridController()
        let frames = Recorder<Void>()
        let owner = NSObject()
        controller.setChangeHandler({ frames.values.append(()) }, owner: owner)

        controller.select(a)
        controller.select(a)
        XCTAssertEqual(frames.values.count, 1)
        controller.reloadLabels()
        controller.labelProvider = { _ in "x" }
        XCTAssertEqual(frames.values.count, 3, "The texts are part of the picture")

        controller.clearChangeHandler(ownedBy: NSObject())
        controller.select(b)
        XCTAssertEqual(frames.values.count, 4, "Another view's teardown does not detach this one")
        controller.clearChangeHandler(ownedBy: owner)
        controller.select(c)
        XCTAssertEqual(frames.values.count, 4)
    }

    func testATapTogglesATile() {
        let controller = ImmersiveMapTileGridController()
        let changes = Recorder<ImmersiveMapTileGridSelectionChange>()
        controller.onSelectionChanged = { changes.values.append($0) }

        XCTAssertEqual(controller.applyTap(a, limit: nil, selectableBounds: nil, coordinate: place, screenPoint: .zero),
                       .toggled)
        XCTAssertEqual(controller.selectedTiles, [a])
        XCTAssertEqual(changes.values.last?.source, .tap)
        XCTAssertEqual(controller.applyTap(a, limit: nil, selectableBounds: nil, coordinate: place, screenPoint: .zero),
                       .toggled)
        XCTAssertTrue(controller.selectedTiles.isEmpty)
        XCTAssertEqual(changes.values.last?.removed, [a])
    }

    func testATapPastTheLimitIsRefusedAndSpent() {
        let controller = ImmersiveMapTileGridController(selectedTiles: [a])
        let rejections = Recorder<ImmersiveMapTileGridTapRejection>()
        controller.onTapRejected = { rejections.values.append($0) }

        let outcome = controller.applyTap(b, limit: 1, selectableBounds: nil, coordinate: place,
                                          screenPoint: CGPoint(x: 3, y: 4))
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(controller.selectedTiles, [a])
        XCTAssertEqual(rejections.values.last?.tile, b)
        XCTAssertEqual(rejections.values.last?.reason, .limitReached(limit: 1))
        XCTAssertEqual(rejections.values.last?.screenPoint, CGPoint(x: 3, y: 4))

        XCTAssertEqual(controller.applyTap(a, limit: 1, selectableBounds: nil, coordinate: place, screenPoint: .zero),
                       .toggled, "A selected tile is always given back")
        XCTAssertTrue(controller.selectedTiles.isEmpty)
        XCTAssertEqual(rejections.values.count, 1)
    }

    func testOneTileAtATimeMovesTheSelection() {
        let controller = ImmersiveMapTileGridController()
        let changes = Recorder<ImmersiveMapTileGridSelectionChange>()
        controller.onSelectionChanged = { changes.values.append($0) }

        XCTAssertEqual(controller.applyTap(a, mode: .single, limit: 1, selectableBounds: nil, coordinate: place,
                                           screenPoint: .zero), .toggled)
        XCTAssertEqual(controller.applyTap(b, mode: .single, limit: 1, selectableBounds: nil, coordinate: place,
                                           screenPoint: .zero), .toggled, "The limit has nothing to limit")
        XCTAssertEqual(controller.selectedTiles, [b])
        XCTAssertEqual(changes.values.last?.added, [b])
        XCTAssertEqual(changes.values.last?.removed, [a], "One change moves the selection")
        XCTAssertEqual(changes.values.count, 2)

        XCTAssertEqual(controller.applyTap(b, mode: .single, limit: nil, selectableBounds: nil, coordinate: place,
                                           screenPoint: .zero), .toggled)
        XCTAssertTrue(controller.selectedTiles.isEmpty, "The gesture on the selected tile takes the selection away")

        // A selection of many, made from code, is replaced whole.
        controller.select([a, b])
        _ = controller.applyTap(c, mode: .single, limit: nil, selectableBounds: nil, coordinate: place, screenPoint: .zero)
        XCTAssertEqual(controller.selectedTiles, [c])
    }

    func testATapOutsideTheAreaIsRefusedAndPassedOn() {
        let controller = ImmersiveMapTileGridController()
        let rejections = Recorder<ImmersiveMapTileGridTapRejection>()
        controller.onTapRejected = { rejections.values.append($0) }
        let far = ImmersiveMapGeoBounds(southWest: GeoCoordinate(latitude: 10, longitude: 10),
                                        northEast: GeoCoordinate(latitude: 11, longitude: 11))

        XCTAssertEqual(controller.applyTap(a, limit: nil, selectableBounds: far, coordinate: place, screenPoint: .zero),
                       .passed)
        XCTAssertTrue(controller.selectedTiles.isEmpty)
        XCTAssertEqual(rejections.values.last?.reason, .outsideSelectableBounds)

        XCTAssertEqual(controller.applyTap(a, limit: nil, selectableBounds: a.bounds, coordinate: place, screenPoint: .zero),
                       .toggled, "A tile that shares an area with the box is selectable")
        // Neither rule holds the app's own calls.
        controller.select(b)
        XCTAssertEqual(controller.selectedTiles, [a, b])
    }
}
