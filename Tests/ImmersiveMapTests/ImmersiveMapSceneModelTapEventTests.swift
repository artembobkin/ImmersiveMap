// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import Foundation
import XCTest
import simd

/// A tap on a 3D model must deliver `ImmersiveMapSceneModelTapEvent` and, with a
/// selection controller attached, select the model; an avatar drawn over it
/// keeps taking the tap, and a removed model stops being selected.
final class ImmersiveMapSceneModelTapEventTests: XCTestCase {
    private let modelID: UInt64 = 11
    private let camera = PickCamera()
    private let flightCoordinate = GeoCoordinate(latitude: 12, longitude: 34)
    private let destinationCoordinate = GeoCoordinate(latitude: 55.75, longitude: 37.61)

    private var modelTapPoint: CGPoint { camera.center }
    private var backgroundTapPoint: CGPoint { CGPoint(x: 10, y: 10) }

    @MainActor
    func testSceneModelTapActionReceivesTheModelWithoutSelectionController() throws {
        let environment = makeEnvironment()
        var receivedEvents: [ImmersiveMapSceneModelTapEvent] = []
        environment.selectionHandler.setSceneModelTapAction { receivedEvents.append($0) }

        let result = environment.selectionHandler.handleMapTap(at: modelTapPoint)

        XCTAssertEqual(result, .consumed)
        XCTAssertEqual(receivedEvents.count, 1)
        XCTAssertEqual(receivedEvents.first?.model.id, modelID)
        XCTAssertEqual(receivedEvents.first?.screenPoint, modelTapPoint)
        XCTAssertNil(environment.selectionHandler.currentMapSelection(),
                     "A tap action without a selection controller must not create a selection")
    }

    /// The event reports where the model was drawn, which mid-flight is not
    /// where the descriptor says it is going.
    @MainActor
    func testTapEventReportsTheDrawnCoordinateRatherThanTheDescriptorDestination() throws {
        let environment = makeEnvironment()
        var receivedEvent: ImmersiveMapSceneModelTapEvent?
        environment.selectionHandler.setSceneModelTapAction { receivedEvent = $0 }

        _ = environment.selectionHandler.handleMapTap(at: modelTapPoint)

        let event = try XCTUnwrap(receivedEvent)
        XCTAssertEqual(event.coordinate.latitude, flightCoordinate.latitude)
        XCTAssertEqual(event.model.coordinate.latitude, destinationCoordinate.latitude)
    }

    @MainActor
    func testSceneModelTapWithoutHandlersFallsBackToBackground() {
        let environment = makeEnvironment()

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: modelTapPoint), .background)
    }

    @MainActor
    func testBackgroundTapDoesNotFireSceneModelTapAction() {
        let environment = makeEnvironment()
        var tapEventCount = 0
        environment.selectionHandler.setSceneModelTapAction { _ in tapEventCount += 1 }

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: backgroundTapPoint), .background)
        XCTAssertEqual(tapEventCount, 0)
    }

    @MainActor
    func testSceneModelTapSelectsWithSceneModelKind() {
        let environment = makeEnvironment()
        let selectionController = ImmersiveMapSelectionController()
        environment.selectionHandler.syncController(selectionController)

        var tapEventCount = 0
        var selectionChangeCount = 0
        environment.selectionHandler.setSceneModelTapAction { _ in tapEventCount += 1 }
        selectionController.onSelectionChanged = { _ in selectionChangeCount += 1 }

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: modelTapPoint), .consumed)
        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: modelTapPoint), .consumed)

        XCTAssertEqual(tapEventCount, 2,
                       "The tap event fires on every tap, including one on an already selected model")
        XCTAssertEqual(selectionChangeCount, 1)
        XCTAssertEqual(environment.selectionHandler.currentMapSelection(),
                       ImmersiveMapSelection(kind: .sceneModel, objectID: modelID))
    }

    @MainActor
    func testBackgroundTapClearsTheSceneModelSelection() {
        let environment = makeEnvironment()
        let selectionController = ImmersiveMapSelectionController()
        environment.selectionHandler.syncController(selectionController)
        var clearedEvents: [ImmersiveMapSelectionClearEvent] = []
        selectionController.onSelectionCleared = { clearedEvents.append($0) }

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: modelTapPoint), .consumed)
        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: backgroundTapPoint), .background)

        XCTAssertNil(environment.selectionHandler.currentMapSelection())
        XCTAssertEqual(clearedEvents.count, 1)
        XCTAssertEqual(clearedEvents.first?.source, .tap)
    }

    /// Avatars are screen-space overlays drawn over the world pass, so one
    /// covering a model takes the tap.
    @MainActor
    func testAvatarOverTheModelWinsTheTap() throws {
        let avatarID: UInt64 = 5
        let environment = makeEnvironment()
        try environment.addAvatar(id: avatarID, covering: modelTapPoint)

        var avatarTapCount = 0
        var sceneModelTapCount = 0
        environment.selectionHandler.setAvatarTapAction { _ in avatarTapCount += 1 }
        environment.selectionHandler.setSceneModelTapAction { _ in sceneModelTapCount += 1 }

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: modelTapPoint), .consumed)
        XCTAssertEqual(avatarTapCount, 1)
        XCTAssertEqual(sceneModelTapCount, 0)
    }

    /// An avatar nothing listens to is not interactive at all, and the model
    /// underneath still gets the tap.
    @MainActor
    func testAvatarWithoutHandlersFallsThroughToTheModel() throws {
        let environment = makeEnvironment()
        try environment.addAvatar(id: 5, covering: modelTapPoint)
        var sceneModelTapCount = 0
        environment.selectionHandler.setSceneModelTapAction { _ in sceneModelTapCount += 1 }

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: modelTapPoint), .consumed)
        XCTAssertEqual(sceneModelTapCount, 1)
    }

    @MainActor
    func testRemovingASelectedModelClearsTheSelection() {
        let environment = makeEnvironment()
        let selectionController = ImmersiveMapSelectionController()
        environment.selectionHandler.syncController(selectionController)
        environment.selectionHandler.setSceneModelTapAction { _ in }
        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: modelTapPoint), .consumed)

        environment.sceneModelsController.remove(id: modelID)

        XCTAssertNil(environment.selectionHandler.currentMapSelection())
    }

    /// A stale snapshot must never win over the current frame's: an in-flight
    /// frame's completion can land after the newer one.
    @MainActor
    func testOlderSnapshotDoesNotReplaceTheCurrentOne() {
        let environment = makeEnvironment()
        environment.selectionHandler.setSceneModelTapAction { _ in }

        environment.selectionHandler.updateSceneModelSelectionSnapshot(
            SceneModelSelectionSnapshot(frameIndex: 1,
                                        drawSize: camera.drawSize,
                                        projectionView: camera.projectionView,
                                        cameraEye: camera.eye,
                                        entries: []))

        XCTAssertEqual(environment.selectionHandler.handleMapTap(at: modelTapPoint), .consumed,
                       "An older frame's snapshot must not displace the current one")
    }

    // MARK: - Helpers

    @MainActor
    private struct Environment {
        let selectionHandler: ImmersiveMapSelectionHandler
        let sceneModelsController: ImmersiveMapSceneModelsController
        let avatarsController: ImmersiveMapAvatarsController
        let drawSize: CGSize

        /// Places an avatar whose hit zone covers `point` (contents scale 1,
        /// snapshot y up).
        func addAvatar(id: UInt64, covering point: CGPoint) throws {
            avatarsController.add(AvatarMarker(id: id,
                                               coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                               image: try Environment.makeTestImage()))
            let anchorPoint = CGPoint(x: point.x, y: drawSize.height - point.y - 50)
            selectionHandler.updateAvatarSelectionSnapshot(
                AvatarSelectionSnapshot(frameIndex: 1,
                                        drawSize: drawSize,
                                        entries: [AvatarSelectionEntry(markerID: id,
                                                                       bounds: CGRect(x: anchorPoint.x - 50,
                                                                                      y: anchorPoint.y,
                                                                                      width: 100,
                                                                                      height: 100),
                                                                       anchorPoint: anchorPoint,
                                                                       drawOrder: 0)])
            )
        }

        private static func makeTestImage() throws -> CGImage {
            var data = Data(repeating: 0xff, count: 4)
            let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
                guard let baseAddress = bytes.baseAddress,
                      let context = CGContext(data: baseAddress,
                                              width: 1,
                                              height: 1,
                                              bitsPerComponent: 8,
                                              bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return nil
                }
                return context.makeImage()
            }
            return try XCTUnwrap(image)
        }
    }

    /// Assembles a selection handler holding one model whose hit volume covers
    /// the viewport center, drawn away from the descriptor's coordinate so the
    /// two can be told apart.
    @MainActor
    private func makeEnvironment() -> Environment {
        let avatarRuntime = ImmersiveMapAvatarRuntime()
        let sceneModelRuntime = ImmersiveMapSceneModelRuntime()
        let viewportRuntime = ImmersiveMapViewportRuntime()
        let renderRuntime = ImmersiveMapRenderRuntime(configuration: ImmersiveMapSettings.default.renderLoop)
        let selectionHandler = ImmersiveMapSelectionHandler(avatarRuntime: avatarRuntime,
                                                            sceneModelRuntime: sceneModelRuntime,
                                                            viewportRuntime: viewportRuntime,
                                                            renderRuntime: renderRuntime)

        let avatarsController = ImmersiveMapAvatarsController()
        avatarRuntime.attachController(avatarsController,
                                       selectionHandler: selectionHandler,
                                       renderRuntime: renderRuntime)

        let sceneModelsController = ImmersiveMapSceneModelsController()
        sceneModelsController.add(ImmersiveMapSceneModel(
            id: modelID,
            source: ImmersiveMapSceneModel.Source(url: URL(fileURLWithPath: "/tmp/model.usdz")),
            coordinate: destinationCoordinate))
        sceneModelRuntime.attachController(sceneModelsController,
                                           selectionHandler: selectionHandler,
                                           renderRuntime: renderRuntime)

        selectionHandler.updateSceneModelSelectionSnapshot(
            SceneModelSelectionSnapshot(frameIndex: 2,
                                        drawSize: camera.drawSize,
                                        projectionView: camera.projectionView,
                                        cameraEye: camera.eye,
                                        entries: [SceneModelSelectionEntry(id: modelID,
                                                                           coordinate: flightCoordinate,
                                                                           modelMatrix: matrix_identity_float4x4,
                                                                           boundsMin: SIMD3<Float>(repeating: -1),
                                                                           boundsMax: SIMD3<Float>(repeating: 1))])
        )

        return Environment(selectionHandler: selectionHandler,
                           sceneModelsController: sceneModelsController,
                           avatarsController: avatarsController,
                           drawSize: camera.drawSize)
    }
}
