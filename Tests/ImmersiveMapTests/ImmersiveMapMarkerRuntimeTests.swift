// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import SwiftUI
import XCTest

/// ImmersiveMapMarkerRuntime must diff the marker set by id, keep the
/// hosting views in the container in collection order, and apply projection
/// snapshots via frame/alpha/isHidden mutations. attach takes a regular
/// platform view: the tests need no Metal host.
@MainActor
final class ImmersiveMapMarkerRuntimeTests: XCTestCase {
    private let hostBounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    func testUpdateCreatesContainerAndHostingViewsInCollectionOrder() {
        let environment = makeEnvironment()

        environment.runtime.update(content: makeContent(ids: [1, 2, 3]))

        let container = try? XCTUnwrap(environment.runtime.markerContainerViewIfLoaded)
        XCTAssertNotNil(container)
        XCTAssertEqual(container?.subviews.count, 3)
        XCTAssertEqual(environment.runtime.currentMarkerProjectionInput.entries.count, 3)
    }

    func testEmptyContentRemovesContainerAndInput() {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1]))
        XCTAssertNotNil(environment.runtime.markerContainerViewIfLoaded)

        environment.runtime.update(content: nil)

        XCTAssertNil(environment.runtime.markerContainerViewIfLoaded)
        XCTAssertEqual(environment.runtime.currentMarkerProjectionInput.entries.count, 0)
    }

    func testUpdateRemovesMissingMarkersAndKeepsInternalID() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1, 2, 3]))
        let inputBefore = environment.runtime.currentMarkerProjectionInput
        let secondInternalID = inputBefore.entries[1].id

        environment.runtime.update(content: makeContent(ids: [2]))

        let container = try XCTUnwrap(environment.runtime.markerContainerViewIfLoaded)
        XCTAssertEqual(container.subviews.count, 1)
        let inputAfter = environment.runtime.currentMarkerProjectionInput
        XCTAssertEqual(inputAfter.entries.count, 1)
        XCTAssertEqual(inputAfter.entries[0].id, secondInternalID,
                       "The internal id of a surviving marker must not change across a diff")
    }

    func testReorderFollowsCollectionOrder() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1, 2]))
        let container = try XCTUnwrap(environment.runtime.markerContainerViewIfLoaded)
        let firstView = container.subviews[0]
        let secondView = container.subviews[1]

        environment.runtime.update(content: makeContent(ids: [2, 1]))

        XCTAssertEqual(container.subviews.count, 2)
        XCTAssertTrue(container.subviews[0] === secondView)
        XCTAssertTrue(container.subviews[1] === firstView)
    }

    func testCoordinateChangeRebuildsProjectionBasis() {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1]))
        let basisBefore = environment.runtime.currentMarkerProjectionInput.entries[0].basis

        environment.runtime.update(content: makeContent(ids: [1], coordinateForID: { _ in
            GeoCoordinate(latitude: 10, longitude: 20)
        }))

        let basisAfter = environment.runtime.currentMarkerProjectionInput.entries[0].basis
        XCTAssertNotEqual(basisBefore, basisAfter)
        XCTAssertEqual(basisAfter, GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 10, longitude: 20)))
    }

    func testNewMarkerHiddenUntilFirstSnapshot() throws {
        let environment = makeEnvironment()

        environment.runtime.update(content: makeContent(ids: [1]))

        let container = try XCTUnwrap(environment.runtime.markerContainerViewIfLoaded)
        XCTAssertTrue(container.subviews[0].isHidden,
                      "Before the first projection snapshot a marker must stay hidden (a flash at (0,0))")
    }

    func testApplyPositionsShowsViewAndAppliesAlpha() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1]))
        let internalID = environment.runtime.currentMarkerProjectionInput.entries[0].id

        // Default viewport contentsScale is 1: the snapshot's drawSize is in points.
        environment.runtime.apply(MarkerProjectionSnapshot(
            frameIndex: 1,
            drawSize: hostBounds.size,
            entries: [MarkerProjectedEntry(id: internalID,
                                           positionPx: SIMD2<Float>(200, 150),
                                           visibilityAlpha: 0.5)]))

        let container = try XCTUnwrap(environment.runtime.markerContainerViewIfLoaded)
        let markerView = container.subviews[0]
        XCTAssertFalse(markerView.isHidden)
        XCTAssertEqual(markerView.frame.midX, 200, accuracy: 0.5)
        XCTAssertEqual(markerView.frame.midY, 150, accuracy: 0.5)
        XCTAssertEqual(viewAlpha(markerView), 0.5, accuracy: 0.001)
    }

    func testMarkerAbsentFromSnapshotIsHidden() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1, 2]))
        let input = environment.runtime.currentMarkerProjectionInput
        let firstInternalID = input.entries[0].id

        environment.runtime.apply(MarkerProjectionSnapshot(
            frameIndex: 1,
            drawSize: hostBounds.size,
            entries: [MarkerProjectedEntry(id: firstInternalID,
                                           positionPx: SIMD2<Float>(100, 100),
                                           visibilityAlpha: 1.0)]))

        let container = try XCTUnwrap(environment.runtime.markerContainerViewIfLoaded)
        XCTAssertFalse(container.subviews[0].isHidden)
        XCTAssertTrue(container.subviews[1].isHidden,
                      "A marker beyond the horizon (absent from the snapshot) must hide")
    }

    func testBottomAnchorShiftsFrameUp() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1], anchor: .bottom))
        let internalID = environment.runtime.currentMarkerProjectionInput.entries[0].id

        environment.runtime.apply(MarkerProjectionSnapshot(
            frameIndex: 1,
            drawSize: hostBounds.size,
            entries: [MarkerProjectedEntry(id: internalID,
                                           positionPx: SIMD2<Float>(200, 150),
                                           visibilityAlpha: 1.0)]))

        let container = try XCTUnwrap(environment.runtime.markerContainerViewIfLoaded)
        let markerView = container.subviews[0]
        XCTAssertEqual(markerView.frame.midX, 200, accuracy: 0.5)
        XCTAssertEqual(markerView.frame.maxY, 150, accuracy: 0.5,
                       "With the .bottom anchor the view's bottom centre must land on the projected point")
    }

    // MARK: - Helpers

    private struct Environment {
        let runtime: ImmersiveMapMarkerRuntime
        let hostView: MarkerOverlayPlatformView
    }

    private func makeEnvironment() -> Environment {
        let runtime = ImmersiveMapMarkerRuntime(
            viewportRuntime: ImmersiveMapViewportRuntime(),
            renderRuntime: ImmersiveMapRenderRuntime(configuration: ImmersiveMapSettings.default.renderLoop))
        let hostView = MarkerOverlayPlatformView(frame: hostBounds)
        runtime.attach(hostView: hostView)
        return Environment(runtime: runtime, hostView: hostView)
    }

    private func makeContent(ids: [Int],
                             coordinateForID: (Int) -> GeoCoordinate = { _ in
                                 GeoCoordinate(latitude: 0, longitude: 0)
                             },
                             anchor: UnitPoint = .center) -> MarkerViewContent {
        MarkerViewContent(anchor: anchor,
                          items: ids.map { id in
                              MarkerViewItem(id: AnyHashable(id),
                                             coordinate: coordinateForID(id),
                                             content: AnyView(Text("marker-\(id)")))
                          })
    }

    private func viewAlpha(_ view: MarkerOverlayPlatformView) -> CGFloat {
        #if canImport(UIKit)
        return view.alpha
        #else
        return view.alphaValue
        #endif
    }
}
