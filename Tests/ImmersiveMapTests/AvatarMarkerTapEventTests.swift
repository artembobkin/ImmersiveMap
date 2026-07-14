// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest

/// Tap по avatar marker должен доставлять `ImmersiveMapMarkerTapEvent` независимо
/// от selection: без `ImmersiveMapSelectionController`, при повторном tap по уже
/// выбранному маркеру, и не должен срабатывать на background tap.
final class AvatarMarkerTapEventTests: XCTestCase {
    private let markerID: UInt64 = 7
    private let markerTapPoint = CGPoint(x: 400, y: 300)
    private let backgroundTapPoint = CGPoint(x: 10, y: 10)

    @MainActor
    func testMarkerTapActionReceivesTappedMarkerWithoutSelectionController() throws {
        let environment = try makeEnvironment()
        var receivedEvents: [ImmersiveMapMarkerTapEvent] = []
        environment.selectionHandler.setMarkerTapAction { event in
            receivedEvents.append(event)
        }

        let result = environment.selectionHandler.handleMapTap(at: markerTapPoint)

        XCTAssertEqual(result, .consumed)
        XCTAssertEqual(receivedEvents.count, 1)
        XCTAssertEqual(receivedEvents.first?.marker.id, markerID)
        XCTAssertEqual(receivedEvents.first?.screenPoint, markerTapPoint)
        XCTAssertNil(environment.selectionHandler.currentMapSelection(),
                     "Tap action без selection controller не должен создавать selection")
    }

    @MainActor
    func testMarkerTapWithoutHandlersFallsBackToBackground() throws {
        let environment = try makeEnvironment()

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: markerTapPoint), .background)
    }

    @MainActor
    func testMarkerTapActionFiresOnRepeatedTapWhileSelectionChangesOnce() throws {
        let environment = try makeEnvironment()
        let selectionController = ImmersiveMapSelectionController()
        environment.selectionHandler.syncController(selectionController)

        var tapEventCount = 0
        var selectionChangeCount = 0
        environment.selectionHandler.setMarkerTapAction { _ in
            tapEventCount += 1
        }
        selectionController.onSelectionChanged = { _ in
            selectionChangeCount += 1
        }

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: markerTapPoint), .consumed)
        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: markerTapPoint), .consumed)

        XCTAssertEqual(tapEventCount, 2,
                       "Tap event приходит на каждое нажатие, включая уже выбранный маркер")
        XCTAssertEqual(selectionChangeCount, 1)
        XCTAssertEqual(environment.selectionHandler.currentMapSelection(),
                       ImmersiveMapSelection(kind: .avatar, objectID: markerID))
    }

    @MainActor
    func testBackgroundTapDoesNotFireMarkerTapAction() throws {
        let environment = try makeEnvironment()
        var tapEventCount = 0
        environment.selectionHandler.setMarkerTapAction { _ in
            tapEventCount += 1
        }

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: backgroundTapPoint), .background)
        XCTAssertEqual(tapEventCount, 0)
    }

    // MARK: - Хелперы

    @MainActor
    private struct Environment {
        let selectionHandler: ImmersiveMapSelectionHandler
        let avatarsController: ImmersiveMapAvatarsController
    }

    /// Собирает selection handler с одним маркером `markerID`, чья hit-зона
    /// накрывает `markerTapPoint` (contentsScale = 1, snapshot Y направлен вверх).
    @MainActor
    private func makeEnvironment() throws -> Environment {
        let avatarRuntime = ImmersiveMapAvatarRuntime()
        let viewportRuntime = ImmersiveMapViewportRuntime()
        let renderRuntime = ImmersiveMapRenderRuntime(configuration: ImmersiveMapSettings.default.renderLoop)
        let selectionHandler = ImmersiveMapSelectionHandler(avatarRuntime: avatarRuntime,
                                                            viewportRuntime: viewportRuntime,
                                                            renderRuntime: renderRuntime)

        let avatarsController = ImmersiveMapAvatarsController()
        avatarsController.add(AvatarMarker(id: markerID,
                                           coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                           image: try Self.makeTestImage()))
        avatarRuntime.attachController(avatarsController,
                                       selectionHandler: selectionHandler,
                                       renderRuntime: renderRuntime)

        let drawSize = CGSize(width: 800, height: 600)
        let anchorPoint = CGPoint(x: markerTapPoint.x,
                                  y: drawSize.height - markerTapPoint.y - 50)
        let bounds = CGRect(x: anchorPoint.x - 50,
                            y: anchorPoint.y,
                            width: 100,
                            height: 100)
        selectionHandler.updateAvatarSelectionSnapshot(
            AvatarSelectionSnapshot(frameIndex: 1,
                                    drawSize: drawSize,
                                    entries: [AvatarSelectionEntry(markerID: markerID,
                                                                   bounds: bounds,
                                                                   anchorPoint: anchorPoint,
                                                                   drawOrder: 0)])
        )
        return Environment(selectionHandler: selectionHandler,
                           avatarsController: avatarsController)
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
