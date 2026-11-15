// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import SwiftUI
import XCTest

/// ImmersiveMapAnnotationRuntime must diff the annotation set by id, keep the
/// hosting views in the container in collection order, and apply projection
/// snapshots via frame/alpha/isHidden mutations. attach takes a regular
/// platform view: the tests need no Metal host.
@MainActor
final class ImmersiveMapAnnotationRuntimeTests: XCTestCase {
    private let hostBounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    func testUpdateCreatesContainerAndHostingViewsInCollectionOrder() {
        let environment = makeEnvironment()

        environment.runtime.update(content: makeContent(ids: [1, 2, 3]))

        let container = try? XCTUnwrap(environment.runtime.annotationContainerViewIfLoaded)
        XCTAssertNotNil(container)
        XCTAssertEqual(container?.subviews.count, 3)
        XCTAssertEqual(environment.runtime.currentAnnotationProjectionInput.entries.count, 3)
    }

    func testEmptyContentRemovesContainerAndInput() {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1]))
        XCTAssertNotNil(environment.runtime.annotationContainerViewIfLoaded)

        environment.runtime.update(content: nil)

        XCTAssertNil(environment.runtime.annotationContainerViewIfLoaded)
        XCTAssertEqual(environment.runtime.currentAnnotationProjectionInput.entries.count, 0)
    }

    func testUpdateRemovesMissingAnnotationsAndKeepsInternalID() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1, 2, 3]))
        let inputBefore = environment.runtime.currentAnnotationProjectionInput
        let secondInternalID = inputBefore.entries[1].id

        environment.runtime.update(content: makeContent(ids: [2]))

        let container = try XCTUnwrap(environment.runtime.annotationContainerViewIfLoaded)
        XCTAssertEqual(container.subviews.count, 1)
        let inputAfter = environment.runtime.currentAnnotationProjectionInput
        XCTAssertEqual(inputAfter.entries.count, 1)
        XCTAssertEqual(inputAfter.entries[0].id, secondInternalID,
                       "The internal id of a surviving annotation must not change across a diff")
    }

    func testReorderFollowsCollectionOrder() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1, 2]))
        let container = try XCTUnwrap(environment.runtime.annotationContainerViewIfLoaded)
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
        let basisBefore = environment.runtime.currentAnnotationProjectionInput.entries[0].basis

        environment.runtime.update(content: makeContent(ids: [1], coordinateForID: { _ in
            GeoCoordinate(latitude: 10, longitude: 20)
        }))

        let basisAfter = environment.runtime.currentAnnotationProjectionInput.entries[0].basis
        XCTAssertNotEqual(basisBefore, basisAfter)
        XCTAssertEqual(basisAfter, GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 10, longitude: 20)))
    }

    func testNewAnnotationHiddenUntilFirstSnapshot() throws {
        let environment = makeEnvironment()

        environment.runtime.update(content: makeContent(ids: [1]))

        let container = try XCTUnwrap(environment.runtime.annotationContainerViewIfLoaded)
        XCTAssertTrue(container.subviews[0].isHidden,
                      "Before the first projection snapshot a annotation must stay hidden (a flash at (0,0))")
    }

    func testApplyPositionsShowsViewAndAppliesAlpha() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1]))
        let internalID = environment.runtime.currentAnnotationProjectionInput.entries[0].id

        // Default viewport contentsScale is 1: the snapshot's drawSize is in points.
        environment.runtime.apply(AnnotationProjectionSnapshot(
            frameIndex: 1,
            drawSize: hostBounds.size,
            entries: [AnnotationProjectedEntry(id: internalID,
                                           positionPx: SIMD2<Float>(200, 150),
                                           visibilityAlpha: 0.5)]))

        let container = try XCTUnwrap(environment.runtime.annotationContainerViewIfLoaded)
        let annotationView = container.subviews[0]
        XCTAssertFalse(annotationView.isHidden)
        XCTAssertEqual(annotationView.frame.midX, 200, accuracy: 0.5)
        XCTAssertEqual(annotationView.frame.midY, 150, accuracy: 0.5)
        XCTAssertEqual(viewAlpha(annotationView), 0.5, accuracy: 0.001)
    }

    func testAnnotationAbsentFromSnapshotIsHidden() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1, 2]))
        let input = environment.runtime.currentAnnotationProjectionInput
        let firstInternalID = input.entries[0].id

        environment.runtime.apply(AnnotationProjectionSnapshot(
            frameIndex: 1,
            drawSize: hostBounds.size,
            entries: [AnnotationProjectedEntry(id: firstInternalID,
                                           positionPx: SIMD2<Float>(100, 100),
                                           visibilityAlpha: 1.0)]))

        let container = try XCTUnwrap(environment.runtime.annotationContainerViewIfLoaded)
        XCTAssertFalse(container.subviews[0].isHidden)
        XCTAssertTrue(container.subviews[1].isHidden,
                      "A annotation beyond the horizon (absent from the snapshot) must hide")
    }

    func testBottomAnchorShiftsFrameUp() throws {
        let environment = makeEnvironment()
        environment.runtime.update(content: makeContent(ids: [1], anchor: .bottom))
        let internalID = environment.runtime.currentAnnotationProjectionInput.entries[0].id

        environment.runtime.apply(AnnotationProjectionSnapshot(
            frameIndex: 1,
            drawSize: hostBounds.size,
            entries: [AnnotationProjectedEntry(id: internalID,
                                           positionPx: SIMD2<Float>(200, 150),
                                           visibilityAlpha: 1.0)]))

        let container = try XCTUnwrap(environment.runtime.annotationContainerViewIfLoaded)
        let annotationView = container.subviews[0]
        XCTAssertEqual(annotationView.frame.midX, 200, accuracy: 0.5)
        XCTAssertEqual(annotationView.frame.maxY, 150, accuracy: 0.5,
                       "With the .bottom anchor the view's bottom centre must land on the projected point")
    }

    // MARK: - Helpers

    private struct Environment {
        let runtime: ImmersiveMapAnnotationRuntime
        let hostView: AnnotationOverlayPlatformView
    }

    private func makeEnvironment() -> Environment {
        let runtime = ImmersiveMapAnnotationRuntime(
            viewportRuntime: ImmersiveMapViewportRuntime(),
            renderRuntime: ImmersiveMapRenderRuntime(configuration: ImmersiveMapSettings.default.renderLoop))
        let hostView = AnnotationOverlayPlatformView(frame: hostBounds)
        runtime.attach(hostView: hostView)
        return Environment(runtime: runtime, hostView: hostView)
    }

    private func makeContent(ids: [Int],
                             coordinateForID: (Int) -> GeoCoordinate = { _ in
                                 GeoCoordinate(latitude: 0, longitude: 0)
                             },
                             anchor: UnitPoint = .center) -> AnnotationViewContent {
        AnnotationViewContent(anchor: anchor,
                          items: ids.map { id in
                              AnnotationViewItem(id: AnyHashable(id),
                                             coordinate: coordinateForID(id),
                                             content: AnyView(Text("marker-\(id)")))
                          })
    }

    /// A annotation keeps its view only when it is certain the view is the
    /// same: both made from elements that compare equal. An element that
    /// cannot be compared, another value or another type is a change.
    func testAAnnotationIsUnchangedOnlyWhenItsElementIsEqual() {
        func item(_ element: AnnotationElement?) -> AnnotationViewItem {
            AnnotationViewItem(id: AnyHashable(1),
                           coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                           content: AnyView(EmptyView()),
                           element: element)
        }

        XCTAssertTrue(item(AnnotationElement("a")).hasSameContent(as: AnnotationElement("a")))
        XCTAssertFalse(item(AnnotationElement("a")).hasSameContent(as: AnnotationElement("b")))
        XCTAssertFalse(item(AnnotationElement("1")).hasSameContent(as: AnnotationElement(1)), "Another type is another element")
        XCTAssertFalse(item(nil).hasSameContent(as: AnnotationElement("a")))
        XCTAssertFalse(item(AnnotationElement("a")).hasSameContent(as: nil))
        XCTAssertFalse(item(nil).hasSameContent(as: nil), "What cannot be compared is taken as changed")
    }

    private func viewAlpha(_ view: AnnotationOverlayPlatformView) -> CGFloat {
        #if canImport(UIKit)
        return view.alpha
        #else
        return view.alphaValue
        #endif
    }
}
