// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// Loads a runtime-written OBJ through the real Model I/O -> MetalKit path.
/// Needs a Metal device (no compiled shader library), so it runs under plain
/// `swift test` on Metal-capable machines and skips elsewhere.
final class SceneModelAssetLoaderTests: XCTestCase {
    private func makeDeviceOrSkip() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        return device
    }

    /// A 2x2x2 cube around the origin without normals: exercises the
    /// addNormals path and gives exact bounds.
    private func writeCubeOBJ() throws -> URL {
        let obj = """
        v -1 -1 -1
        v 1 -1 -1
        v 1 1 -1
        v -1 1 -1
        v -1 -1 1
        v 1 -1 1
        v 1 1 1
        v -1 1 1
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
            .appendingPathComponent("scene-model-loader-\(UUID().uuidString)")
            .appendingPathExtension("obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadsCubeWithBoundsMaterialsAndCanonicalLayout() throws {
        let device = try makeDeviceOrSkip()
        let url = try writeCubeOBJ()
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try SceneModelAssetLoader.load(url: url, device: device)

        XCTAssertEqual(mesh.meshes.count, 1)
        XCTAssertEqual(mesh.localTransforms.count, 1)
        XCTAssertEqual(mesh.materials.count, 1)
        XCTAssertEqual(mesh.materials[0].count, mesh.meshes[0].submeshes.count)
        XCTAssertGreaterThan(mesh.meshes[0].submeshes.count, 0)
        XCTAssertEqual(mesh.meshes[0].vertexBuffers.count, 1,
                       "The canonical layout interleaves everything into one buffer")

        XCTAssertEqual(mesh.localBounds.maxExtent, 2, accuracy: 1e-4)
        XCTAssertEqual(mesh.localBounds.radius, Float(3.0).squareRoot(), accuracy: 1e-3)
        XCTAssertEqual(mesh.localBounds.center.x, 0, accuracy: 1e-4)
        XCTAssertGreaterThan(mesh.costInBytes, 0)
    }

    func testUnsupportedExtensionThrowsTypedError() throws {
        let device = try makeDeviceOrSkip()
        let url = URL(fileURLWithPath: "/tmp/model.definitely-not-a-model")

        XCTAssertThrowsError(try SceneModelAssetLoader.load(url: url, device: device)) { error in
            XCTAssertEqual(error as? SceneModelAssetLoadError,
                           .unsupportedFormat("definitely-not-a-model"))
        }
    }

    func testMissingFileThrowsUnreadableAsset() throws {
        let device = try makeDeviceOrSkip()
        let url = URL(fileURLWithPath: "/tmp/scene-model-missing-\(UUID().uuidString).obj")

        XCTAssertThrowsError(try SceneModelAssetLoader.load(url: url, device: device)) { error in
            XCTAssertEqual(error as? SceneModelAssetLoadError, .unreadableAsset(url))
        }
    }
}

/// State machine of the mesh store with an injected loader: dedup, retry
/// accounting, LRU protection, and eventSink invalidation.
final class SceneModelMeshStoreTests: XCTestCase {
    private final class RecordingEventSink: RenderFrameEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [RenderInvalidationReason] = []

        var invalidationCount: Int {
            lock.withLock { reasons.count }
        }

        func invalidate(_ reason: RenderInvalidationReason) {
            lock.withLock { reasons.append(reason) }
        }

        func applyActivityState(_ state: RenderActivityState) {}
        func completeSceneModelPathAnimations(ids _: [UInt64]) {}

        func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot) {}
        func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?) {}
        func updateMarkerProjectionSnapshot(_ snapshot: MarkerProjectionSnapshot) {}
    }

    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }

        var count: Int {
            lock.withLock { value }
        }
    }

    private func makeDeviceOrSkip() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        return device
    }

    /// Built inside the loader closure: SceneModelMesh holds Metal objects and
    /// is not Sendable, so it must not be captured across the closure boundary.
    private static func makeEmptyMesh() -> SceneModelMesh {
        SceneModelMesh(meshes: [],
                       localTransforms: [],
                       materials: [],
                       localBounds: SceneModelMesh.Bounds(center: .zero, radius: 1, maxExtent: 1),
                       costInBytes: 64)
    }

    private func waitUntil(timeout: TimeInterval = 3.0,
                           _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testSuccessfulLoadBecomesReadyAndInvalidatesFrame() async throws {
        let device = try makeDeviceOrSkip()
        let sink = RecordingEventSink()
        let counter = LoadCounter()
        let store = SceneModelMeshStore(device: device,
                                        loadAsset: { _, _ in
                                            _ = counter.increment()
                                            return Self.makeEmptyMesh()
                                        })
        store.eventSink = sink
        let url = URL(fileURLWithPath: "/tmp/ready.usdz")

        XCTAssertTrue(store.requestMeshes(for: [url]).isEmpty, "First request only starts the load")
        let becameReady = try await waitUntil { store.requestMeshes(for: [url]).isEmpty == false }
        XCTAssertTrue(becameReady)
        XCTAssertEqual(counter.count, 1, "Repeated requests must not restart a finished load")
        XCTAssertGreaterThanOrEqual(sink.invalidationCount, 1)
    }

    func testFailedLoadRecordsAttemptAndWaitsForCooldown() async throws {
        let device = try makeDeviceOrSkip()
        let counter = LoadCounter()
        let store = SceneModelMeshStore(device: device,
                                        loadAsset: { url, _ in
                                            _ = counter.increment()
                                            throw SceneModelAssetLoadError.unreadableAsset(url)
                                        })
        let url = URL(fileURLWithPath: "/tmp/broken.usdz")

        XCTAssertTrue(store.requestMeshes(for: [url]).isEmpty)
        let failed = try await waitUntil { store.failureAttempts(for: url) == 1 }
        XCTAssertTrue(failed)

        // The cooldown has not expired: a new request must not spawn a retry.
        XCTAssertTrue(store.requestMeshes(for: [url]).isEmpty)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.count, 1)
    }
}
