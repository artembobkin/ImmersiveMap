// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The frame reports how many scene model meshes it is still waiting for.
///
/// Without that number nothing downstream can tell "this scene has no models"
/// from "the models have not arrived yet": meshes load on a detached task, and
/// a statically placed model raises no animation activity while it loads. The
/// still capture reads this counter to decide it has waited long enough, and
/// the video export refuses scene models outright rather than face the same
/// question.
///
/// Requires the compiled Metal library, so it skips under `swift test` and
/// runs in the xcodebuild workspace suite.
final class SceneModelPendingMeshDiagnosticsTests: XCTestCase {
    @MainActor
    func testAFrameReportsTheMeshesItIsStillWaitingFor() async throws {
        let harness = try OffscreenFrameHarness.makeOrSkip(size: 96)
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                             longitudeDegrees: 0,
                                                             zoom: 16))

        try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        XCTAssertEqual(pendingMeshCount(harness), 0,
                       "A scene with no models is waiting for nothing")

        let objURL = try writeCubeOBJ()
        defer { try? FileManager.default.removeItem(at: objURL) }
        harness.sceneModels.add(ImmersiveMapSceneModel(
            id: 1,
            source: ImmersiveMapSceneModel.Source(url: objURL),
            coordinate: GeoCoordinate(latitude: 0, longitude: 0),
            fitDiameterMeters: 400))

        // The frame that first asks for the mesh cannot already have it: the
        // load is dispatched from this very frame onto another task.
        try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(1))
        XCTAssertEqual(pendingMeshCount(harness), 1,
                       "The frame that starts the load must report the model as outstanding")

        // And the count has to come back down, or anything waiting on it would
        // wait forever.
        var settled = false
        for frameIndex in 2...200 where settled == false {
            try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(frameIndex))
            settled = pendingMeshCount(harness) == 0
            if settled == false {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertTrue(settled, "The pending count must drop once the mesh arrives")
    }

    @MainActor
    private func pendingMeshCount(_ harness: OffscreenFrameHarness) -> Int {
        harness.engine.currentDiagnostics?.counterValue(.pendingSceneModelMeshes) ?? -1
    }

    private func writeCubeOBJ() throws -> URL {
        let obj = """
        v -1 0 -1
        v 1 0 -1
        v 1 2 -1
        v -1 2 -1
        v -1 0 1
        v 1 0 1
        v 1 2 1
        v -1 2 1
        f 1 3 2
        f 1 4 3
        f 5 6 7
        f 5 7 8
        f 1 2 6
        f 1 6 5
        f 2 3 7
        f 2 7 6
        f 3 4 8
        f 3 8 7
        f 4 1 5
        f 4 5 8
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-mesh-cube-\(UUID().uuidString)")
            .appendingPathExtension("obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
