// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest

/// A tap on a pin pin must deliver `ImmersiveMapPinTapEvent` regardless
/// of selection: without an `ImmersiveMapSelectionController`, on a repeated tap
/// on an already selected pin, and it must not fire on a background tap.
final class ImmersiveMapPinTapEventTests: XCTestCase {
    private let pinID: UInt64 = 7
    private let pinTapPoint = CGPoint(x: 400, y: 300)
    private let backgroundTapPoint = CGPoint(x: 10, y: 10)

    @MainActor
    func testPinTapActionReceivesTappedPinWithoutSelectionController() throws {
        let environment = try makeEnvironment()
        var receivedEvents: [ImmersiveMapPinTapEvent] = []
        environment.pinSelection.tapAction = { event in
            receivedEvents.append(event)
        }

        let result = environment.selectionHandler.handleMapTap(at: pinTapPoint)

        XCTAssertEqual(result, .consumed)
        XCTAssertEqual(receivedEvents.count, 1)
        XCTAssertEqual(receivedEvents.first?.pin.id, pinID)
        XCTAssertEqual(receivedEvents.first?.screenPoint, pinTapPoint)
        XCTAssertNil(environment.selectionHandler.currentMapSelection(),
                     "A tap action without a selection controller must not create a selection")
    }

    @MainActor
    func testPinTapWithoutHandlersFallsBackToBackground() throws {
        let environment = try makeEnvironment()

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: pinTapPoint), .background)
    }

    @MainActor
    func testPinTapActionFiresOnRepeatedTapWhileSelectionChangesOnce() throws {
        let environment = try makeEnvironment()
        let selectionController = ImmersiveMapSelectionController()
        environment.selectionHandler.syncController(selectionController)

        var tapEventCount = 0
        var selectionChangeCount = 0
        environment.pinSelection.tapAction = { _ in
            tapEventCount += 1
        }
        selectionController.onSelectionChanged = { _ in
            selectionChangeCount += 1
        }

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: pinTapPoint), .consumed)
        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: pinTapPoint), .consumed)

        XCTAssertEqual(tapEventCount, 2,
                       "A tap event arrives on every tap, including one on an already selected pin")
        XCTAssertEqual(selectionChangeCount, 1)
        XCTAssertEqual(environment.selectionHandler.currentMapSelection(),
                       ImmersiveMapSelection(kind: .pin, objectID: pinID))
    }

    @MainActor
    func testBackgroundTapDoesNotFirePinTapAction() throws {
        let environment = try makeEnvironment()
        var tapEventCount = 0
        environment.pinSelection.tapAction = { _ in
            tapEventCount += 1
        }

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: backgroundTapPoint), .background)
        XCTAssertEqual(tapEventCount, 0)
    }

    // MARK: - Helpers

    @MainActor
    private struct Environment {
        let selectionHandler: ImmersiveMapSelectionHandler
        let pinSelection: PinSelection
        let pinsController: ImmersiveMapPinsController
    }

    /// Assembles a selection handler with a single pin `pinID` whose hit zone
    /// covers `pinTapPoint` (contentsScale = 1, snapshot Y points up).
    @MainActor
    private func makeEnvironment() throws -> Environment {
        let pinRuntime = ImmersiveMapPinRuntime()
        let viewportRuntime = ImmersiveMapViewportRuntime()
        let renderRuntime = ImmersiveMapRenderRuntime(configuration: ImmersiveMapSettings.default.renderLoop)
        let pinSelection = PinSelection(source: pinRuntime)
        let selectionHandler = ImmersiveMapSelectionHandler(
            host: ImmersiveMapSelectionHost(viewportRuntime: viewportRuntime,
                                            renderRuntime: renderRuntime),
            features: [pinSelection])

        let pinsController = ImmersiveMapPinsController()
        pinsController.add(ImmersiveMapPin(id: pinID,
                                           coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                           image: try Self.makeTestImage()))
        pinRuntime.attachController(pinsController,
                                       selectionHandler: selectionHandler,
                                       renderRuntime: renderRuntime)

        let drawSize = CGSize(width: 800, height: 600)
        let anchorPoint = CGPoint(x: pinTapPoint.x,
                                  y: drawSize.height - pinTapPoint.y - 50)
        let bounds = CGRect(x: anchorPoint.x - 50,
                            y: anchorPoint.y,
                            width: 100,
                            height: 100)
        selectionHandler.updatePickData([
            PinSelectionSnapshot(frameIndex: 1,
                                    drawSize: drawSize,
                                    entries: [PinSelectionEntry(pinID: pinID,
                                                                   bounds: bounds,
                                                                   anchorPoint: anchorPoint,
                                                                   drawOrder: 0)])
        ])
        return Environment(selectionHandler: selectionHandler,
                           pinSelection: pinSelection,
                           pinsController: pinsController)
    }

    private static func makeTestImage() throws -> CGImage {
        let bytesPerRow = 4
        var data = Data(repeating: 0xff, count: bytesPerRow)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return context.makeImage()
        }
        return try XCTUnwrap(image)
    }
}
