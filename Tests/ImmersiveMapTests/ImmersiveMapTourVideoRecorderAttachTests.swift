// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Attach-lifecycle tests exercise only the guard chain that runs before any
/// Metal or AVFoundation work, so they are safe in every test environment.
/// The guard order is: exporting → attached → shots → configuration → Metal.
@MainActor
final class ImmersiveMapTourVideoRecorderAttachTests: XCTestCase {
    private final class Owner {}

    private func makeContext() -> ImmersiveMapVideoExportAttachContext {
        ImmersiveMapVideoExportAttachContext(currentSettings: { .default },
                                             currentCameraPosition: { nil },
                                             currentAvatarsController: { nil },
                                             currentMarkerContent: { nil })
    }

    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("immersive-map-recorder-test-\(UUID().uuidString).mov")
    }

    private func exportError(_ recorder: ImmersiveMapTourVideoRecorder,
                             shots: [ImmersiveMapCameraTourShot] = [],
                             configuration: ImmersiveMapVideoExportConfiguration = .default)
        async -> ImmersiveMapVideoExportError? {
        do {
            try await recorder.export(shots: shots, configuration: configuration, to: makeTemporaryURL())
            return nil
        } catch let error as ImmersiveMapVideoExportError {
            return error
        } catch {
            XCTFail("Unexpected error type: \(error)")
            return nil
        }
    }

    func testExportWithoutAttachThrowsNotAttached() async {
        let recorder = ImmersiveMapTourVideoRecorder()

        let error = await exportError(recorder)

        guard case .notAttached = error else {
            return XCTFail("Expected notAttached, got \(String(describing: error))")
        }
        XCTAssertFalse(recorder.isExporting)
    }

    func testAttachedRecorderRejectsEmptyShots() async {
        let recorder = ImmersiveMapTourVideoRecorder()
        let owner = Owner()
        recorder.attachRuntime(owner: owner, context: makeContext())

        let error = await exportError(recorder)

        guard case .emptyShots = error else {
            return XCTFail("Expected emptyShots, got \(String(describing: error))")
        }
    }

    func testStaleOwnerDetachKeepsNewAttachment() async {
        let recorder = ImmersiveMapTourVideoRecorder()
        let currentOwner = Owner()
        let staleOwner = Owner()
        recorder.attachRuntime(owner: currentOwner, context: makeContext())

        recorder.detachRuntime(owner: staleOwner)

        // Still attached: the guard chain reaches the shots check.
        let error = await exportError(recorder)
        guard case .emptyShots = error else {
            return XCTFail("Expected emptyShots (still attached), got \(String(describing: error))")
        }
    }

    func testOwnerDetachClearsAttachment() async {
        let recorder = ImmersiveMapTourVideoRecorder()
        let owner = Owner()
        recorder.attachRuntime(owner: owner, context: makeContext())

        recorder.detachRuntime(owner: owner)

        let error = await exportError(recorder)
        guard case .notAttached = error else {
            return XCTFail("Expected notAttached after detach, got \(String(describing: error))")
        }
    }

    func testInvalidConfigurationIsRejectedBeforeAnyRendering() async {
        let recorder = ImmersiveMapTourVideoRecorder()
        recorder.attachRuntime(owner: Owner(), context: makeContext())
        let shot = ImmersiveMapCameraTourShot(position: ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                                                   longitudeDegrees: 0,
                                                                                   zoom: 3,
                                                                                   bearing: 0,
                                                                                   pitch: 0))
        var configuration = ImmersiveMapVideoExportConfiguration.default
        configuration.width = 1919

        let error = await exportError(recorder, shots: [shot], configuration: configuration)

        guard case .invalidConfiguration = error else {
            return XCTFail("Expected invalidConfiguration, got \(String(describing: error))")
        }
        XCTAssertFalse(recorder.isExporting)
    }

    func testCancelWithoutActiveExportIsANoOp() {
        let recorder = ImmersiveMapTourVideoRecorder()
        recorder.cancel()
        XCTAssertFalse(recorder.isExporting)
    }
}
