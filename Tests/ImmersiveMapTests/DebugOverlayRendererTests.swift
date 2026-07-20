// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class DebugOverlayRendererTests: XCTestCase {
    func testDebugPanelHudDoesNotRequireMetalDebugPass() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let controls = DebugOverlayControlState()

        XCTAssertFalse(RenderDebugOverlayPolicy.shouldEncode(settings, controls: controls.snapshot()))
    }

    func testTileLayerDebugRequiresMetalDebugPass() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let controls = DebugOverlayControlState()
        controls.setTileLayersEnabled(true)

        XCTAssertTrue(RenderDebugOverlayPolicy.shouldEncode(settings, controls: controls.snapshot()))
    }

    func testAxesDebugRequiresMetalDebugPass() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let controls = DebugOverlayControlState()
        controls.setAxesEnabled(true)

        XCTAssertTrue(RenderDebugOverlayPolicy.shouldEncode(settings, controls: controls.snapshot()))
    }

    func testWireframeDebugDoesNotRequireMetalDebugPass() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let controls = DebugOverlayControlState()
        controls.setWireframeEnabled(true)

        XCTAssertFalse(RenderDebugOverlayPolicy.shouldEncode(settings, controls: controls.snapshot()))
    }

    func testDebugControlsDoNotEncodeWhenPanelIsDisabled() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = false
        let controls = DebugOverlayControlState()
        controls.setAxesEnabled(true)
        controls.setTileLayersEnabled(true)
        controls.setWireframeEnabled(true)

        XCTAssertFalse(RenderDebugOverlayPolicy.shouldEncode(settings, controls: controls.snapshot()))
    }

    func testHudSnapshotIsNilWhenDebugPanelIsDisabled() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = false

        let snapshot = DebugOverlayHUDSnapshot.make(
            settings: settings,
            zoom: 4,
            latitude: 55,
            longitude: 37,
            cameraDebugLines: [],
            diagnostics: nil
        )

        XCTAssertNil(snapshot)
    }

    func testHudSnapshotIncludesCoordinatesAndDiagnosticsLines() {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let diagnostics = FrameDiagnostics(frameIndex: 42, frameTime: 16.7)

        let snapshot = DebugOverlayHUDSnapshot.make(
            settings: settings,
            zoom: 5.412,
            latitude: 55.7558,
            longitude: 37.6173,
            cameraDebugLines: ["camera z:5.41 pitch:36.00 bearing:18.00"],
            diagnostics: diagnostics
        )

        XCTAssertEqual(snapshot?.coordinateLines.zoom, "z: 5.41")
        XCTAssertEqual(snapshot?.coordinateLines.latLon, "lat: 55.756 lon: 37.617")
        XCTAssertTrue(snapshot?.diagnosticsLines.contains("[Camera]") == true)
        XCTAssertTrue(snapshot?.diagnosticsLines.contains("camera z:5.41 pitch:36.00 bearing:18.00") == true)
        XCTAssertTrue(snapshot?.diagnosticsLines.contains { $0.hasPrefix("frame:42") } == true)
    }

    func testHudSnapshotIncludesAtlasPagesWhenSummaryExists() throws {
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let summary = TileAtlasDebugSummary(plan: try makeSingleAllocationAtlasPlan())

        let snapshot = DebugOverlayHUDSnapshot.make(
            settings: settings,
            zoom: 5.412,
            latitude: 55.7558,
            longitude: 37.6173,
            cameraDebugLines: [],
            diagnostics: nil,
            atlasDebugSummary: summary
        )

        XCTAssertEqual(snapshot?.atlasPages.count, 1)
        XCTAssertEqual(snapshot?.atlasPages[0].allocations.first?.targetTile, Tile(x: 0, y: 0, z: 1))
    }

    func testAtlasAllocationLabelUsesTargetTileCoordinate() {
        let allocation = TileAtlasDebugAllocation(pageIndex: 0,
                                                   slotColumn: 0,
                                                   slotRow: 0,
                                                   slotsPerSide: 4,
                                                   cellSizePx: 1024,
                                                   atlasDepth: .depth2,
                                                   sourceTile: Tile(x: 0, y: 0, z: 2),
                                                   targetTile: Tile(x: 2, y: 1, z: 2),
                                                   screenDemandPx: 512,
                                                   isFallback: false)

        XCTAssertEqual(allocation.atlasPreviewLabel, "z2/2/1")
    }

    func testTileCoordinateDebugLabelUsesXYZOrder() {
        let tile = Tile(x: 154, y: 79, z: 8)

        XCTAssertEqual(DebugOverlayRenderer.formatTileCoordinateString(tile), "tile = 154/79/8")
    }

    func testTileCoordinateWatermarkAnchorsAreDistributedInsideTile() {
        XCTAssertEqual(DebugOverlayRenderer.makeTileWatermarkUVs(gridSize: 3), [
            SIMD2<Float>(0.25, 0.25),
            SIMD2<Float>(0.50, 0.25),
            SIMD2<Float>(0.75, 0.25),
            SIMD2<Float>(0.25, 0.50),
            SIMD2<Float>(0.50, 0.50),
            SIMD2<Float>(0.75, 0.50),
            SIMD2<Float>(0.25, 0.75),
            SIMD2<Float>(0.50, 0.75),
            SIMD2<Float>(0.75, 0.75)
        ])
    }

    func testTileCoordinateWatermarkProjectionInputsUseOnlyLocalBasisPoints() {
        let metrics = TextMetrics(
            size: TextSize(width: 100, height: 20),
            vertices: [
                LabelVertex(position: SIMD2<Float>(0, 0), uv: .zero, labelIndex: 0),
                LabelVertex(position: SIMD2<Float>(100, 20), uv: .zero, labelIndex: 0)
            ]
        )
        let tile = Tile(x: 154, y: 79, z: 8)

        let inputs = DebugOverlayRenderer.makeTileWatermarkProjectionPointInputs(
            anchorUV: SIMD2<Float>(0.5, 0.5),
            metrics: metrics,
            tile: tile,
            maxWidthUV: 0.2,
            maxHeightUV: 0.1
        )

        XCTAssertEqual(inputs.map(\.uv), [
            SIMD2<Float>(0.5, 0.5),
            SIMD2<Float>(0.502, 0.5),
            SIMD2<Float>(0.5, 0.498)
        ])
        XCTAssertEqual(inputs.map(\.tile), [
            SIMD3<Int32>(154, 79, 8),
            SIMD3<Int32>(154, 79, 8),
            SIMD3<Int32>(154, 79, 8)
        ])
    }

    func testTileCoordinateWatermarkProjectionInputsAccountForPadding() {
        let metrics = TextMetrics(
            size: TextSize(width: 100, height: 20),
            vertices: [
                LabelVertex(position: SIMD2<Float>(0, 0), uv: .zero, labelIndex: 0)
            ]
        )
        let tile = Tile(x: 154, y: 79, z: 8)

        let inputs = DebugOverlayRenderer.makeTileWatermarkProjectionPointInputs(
            anchorUV: SIMD2<Float>(0.5, 0.5),
            metrics: metrics,
            tile: tile,
            maxWidthUV: 0.2,
            maxHeightUV: 0.1,
            paddingPx: SIMD2<Float>(8, 4)
        )

        XCTAssertEqual(inputs.map(\.uv), [
            SIMD2<Float>(0.5, 0.5),
            SIMD2<Float>(0.5017241, 0.5),
            SIMD2<Float>(0.5, 0.49827588)
        ])
    }

    func testTileCoordinateWatermarkUsesSmallTextStrokeWidth() {
        XCTAssertEqual(DebugOverlayRenderer.makeTileWatermarkTextStyle().strokeWidthPx, 2.0)
    }

    func testTileWatermarkScreenPlacementReturnsAxesForOnScreenAnchor() {
        let placement = DebugOverlayRenderer.makeTileWatermarkScreenPlacement(
            center: SIMD2<Float>(500, 400),
            xUnitPoint: SIMD2<Float>(502, 400),
            yUnitPoint: SIMD2<Float>(500, 398),
            textSize: SIMD2<Float>(100, 20),
            viewportSize: SIMD2<Float>(1000, 800)
        )

        XCTAssertEqual(placement, TileWatermarkScreenPlacement(xAxis: SIMD2<Float>(2, 0),
                                                               yAxis: SIMD2<Float>(0, -2)))
    }

    func testTileWatermarkScreenPlacementRejectsBlownUpProjectionAxes() {
        let placement = DebugOverlayRenderer.makeTileWatermarkScreenPlacement(
            center: SIMD2<Float>(500, 400),
            xUnitPoint: SIMD2<Float>(120_500, 400),
            yUnitPoint: SIMD2<Float>(500, -95_600),
            textSize: SIMD2<Float>(100, 20),
            viewportSize: SIMD2<Float>(1000, 800)
        )

        XCTAssertNil(placement)
    }

    func testTileWatermarkScreenPlacementRejectsNonFiniteProjection() {
        let placement = DebugOverlayRenderer.makeTileWatermarkScreenPlacement(
            center: SIMD2<Float>(.infinity, 400),
            xUnitPoint: SIMD2<Float>(502, 400),
            yUnitPoint: SIMD2<Float>(500, 398),
            textSize: SIMD2<Float>(100, 20),
            viewportSize: SIMD2<Float>(1000, 800)
        )

        XCTAssertNil(placement)
    }

    func testTileWatermarkScreenPlacementRejectsFullyOffscreenText() {
        let placement = DebugOverlayRenderer.makeTileWatermarkScreenPlacement(
            center: SIMD2<Float>(-500, 400),
            xUnitPoint: SIMD2<Float>(-498, 400),
            yUnitPoint: SIMD2<Float>(-500, 398),
            textSize: SIMD2<Float>(100, 20),
            viewportSize: SIMD2<Float>(1000, 800)
        )

        XCTAssertNil(placement)
    }

    func testTileWatermarkScreenPlacementKeepsPartiallyVisibleText() {
        let placement = DebugOverlayRenderer.makeTileWatermarkScreenPlacement(
            center: SIMD2<Float>(-40, 400),
            xUnitPoint: SIMD2<Float>(-38, 400),
            yUnitPoint: SIMD2<Float>(-40, 398),
            textSize: SIMD2<Float>(100, 20),
            viewportSize: SIMD2<Float>(1000, 800)
        )

        XCTAssertNotNil(placement)
    }

    func testOverlayDiagnosticsIncludeCameraLinesWithoutFrameDiagnostics() {
        let lines = DebugOverlayRenderer.makeOverlayDiagnosticsTextLines(
            cameraDebugLines: ["camera z:5.41 pitch:36.00 bearing:18.00"],
            diagnostics: nil
        )

        XCTAssertEqual(lines, ["camera z:5.41 pitch:36.00 bearing:18.00"])
    }

    func testOverlayDiagnosticsPrependCameraLinesBeforeFrameDiagnostics() {
        let diagnostics = FrameDiagnostics(frameIndex: 42, frameTime: 16.7)

        let lines = DebugOverlayRenderer.makeOverlayDiagnosticsTextLines(
            cameraDebugLines: ["camera z:5.41 pitch:36.00 bearing:18.00"],
            diagnostics: diagnostics
        )

        XCTAssertEqual(Array(lines.prefix(2)), ["[Camera]", "camera z:5.41 pitch:36.00 bearing:18.00"])
        XCTAssertTrue(lines.contains("[Frame]"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("frame:42") })
    }

    func testOverlayDiagnosticsIncludeRamUsageWhenAvailable() {
        let diagnostics = FrameDiagnostics(frameIndex: 42, frameTime: 16.7)

        let lines = DebugOverlayRenderer.makeOverlayDiagnosticsTextLines(
            cameraDebugLines: [],
            diagnostics: diagnostics,
            memorySnapshot: ProcessMemorySnapshot(physicalFootprintBytes: 128 * 1024 * 1024)
        )

        XCTAssertTrue(lines.contains("memory ram:128.0MB"))
    }

    func testOverlayDiagnosticsGroupsStatsAndAddsFPS() {
        let diagnostics = FrameDiagnostics(frameIndex: 909, frameTime: 67.44)
        diagnostics.setCounter(.visibleTiles, value: 16)
        diagnostics.setCounter(.readyTiles, value: 25)
        diagnostics.setCounter(.requestedTiles, value: 0)
        diagnostics.setCounter(.renderedTiles, value: 16)
        diagnostics.setCounter(.baseLabelCount, value: 181)
        diagnostics.setCounter(.roadLabelGlyphCount, value: 0)
        diagnostics.setCounter(.roadLabelInstanceCount, value: 0)
        diagnostics.setCounter(.roadLabelNearCameraCulledPathCount, value: 12)
        diagnostics.setCounter(.roadLabelNearCameraCulledAnchorCount, value: 34)
        diagnostics.setCounter(.resourceBufferCount, value: 1)
        diagnostics.setCounter(.resourceTextureCount, value: 3)
        diagnostics.setCounter(.resourcePipelineCount, value: 5)
        diagnostics.setCounter(.globeCullingVisitedNodes, value: 85)
        diagnostics.setCounter(.globeCullingFrustumRejects, value: 15)
        diagnostics.setCounter(.globeCullingHorizonRejects, value: 33)
        diagnostics.setCounter(.globeCullingAcceptedLeafTiles, value: 16)
        diagnostics.setCounter(.globeCullingAcceptedWholeSubtrees, value: 0)
        diagnostics.setMeasurement(.globeCullingDurationMs, value: 0.07)
        diagnostics.recordSkipReason(.debugOverlayDisabled)
        diagnostics.recordSkipReason(.noAvatarContent)

        let lines = DebugOverlayRenderer.makeOverlayDiagnosticsTextLines(
            cameraDebugLines: [
                "camera z:3.93 pitch:0.00 bearing:15.00",
                "surface:globe transition:0.00 viewport:3298x1996"
            ],
            diagnostics: diagnostics,
            memorySnapshot: ProcessMemorySnapshot(physicalFootprintBytes: 128 * 1024 * 1024)
        )

        XCTAssertEqual(lines, [
            "[Camera]",
            "camera z:3.93 pitch:0.00 bearing:15.00",
            "surface:globe transition:0.00 viewport:3298x1996",
            "",
            "[Frame]",
            "frame:909 dt:67.44ms fps:14.8",
            "memory ram:128.0MB",
            "",
            "[Tiles]",
            "vis:16 ready:25 req:0 draw:16",
            "",
            "[Labels]",
            "base:181 bT:0/0/0 roadG:0 roadI:0 roadCull:12/34",
            "",
            "[Resources]",
            "buffers:1 textures:3 pipelines:5",
            "",
            "[Globe culling]",
            "ms:0.07 nodes:85 frustum:15 horizon:33 leaf:16 subtree:0",
            "",
            "[Skip]",
            "debugOverlayDisabled,noAvatarContent"
        ])
    }

    func testDiagnosticsTextStylePlannerMarksSectionsKeysAndWarningSkipBody() {
        let text = [
            "[Frame]",
            "frame:73 dt:3.55ms fps:281.9",
            "",
            "[Skip]",
            "debugOverlayDisabled,noAvatarContent"
        ].joined(separator: "\n")

        let runs = DebugOverlayDiagnosticsTextStylePlanner.makeRuns(for: text)

        XCTAssertTrue(runs.contains(DebugOverlayDiagnosticsTextStyleRun(
            range: (text as NSString).range(of: "[Frame]"),
            style: .section("Frame")
        )))
        XCTAssertTrue(runs.contains(DebugOverlayDiagnosticsTextStyleRun(
            range: (text as NSString).range(of: "frame:"),
            style: .key
        )))
        XCTAssertTrue(runs.contains(DebugOverlayDiagnosticsTextStyleRun(
            range: (text as NSString).range(of: "dt:"),
            style: .key
        )))
        XCTAssertTrue(runs.contains(DebugOverlayDiagnosticsTextStyleRun(
            range: (text as NSString).range(of: "[Skip]"),
            style: .section("Skip")
        )))
        XCTAssertTrue(runs.contains(DebugOverlayDiagnosticsTextStyleRun(
            range: (text as NSString).range(of: "debugOverlayDisabled,noAvatarContent"),
            style: .warningValue
        )))
        XCTAssertFalse(runs.contains { run in
            run.range == (text as NSString).range(of: "73") && run.style == .key
        })
    }

    private func makeSingleAllocationAtlasPlan() throws -> TileAtlasPlan {
        let sourceTile = Tile(x: 0, y: 0, z: 1)
        let targetTile = Tile(x: 0, y: 0, z: 1)
        let metalTile = MetalTile(tile: sourceTile, tileBuffers: try makeTileBuffers())
        let placeTile = PlaceTile(metalTile: metalTile,
                                  placeIn: VisibleTile(tile: targetTile),
                                  lodKind: .exact)
        let candidate = TileAtlasCandidate(placementIndex: 0,
                                            placeTile: placeTile,
                                            screenDemandPx: 128,
                                            distanceToCamera: 0,
                                            desiredDepth: .depth4)
        let allocation = TileAtlasAllocation(candidate: candidate,
                                              pageIndex: 0,
                                              placedPosition: PlacedPos(depth: 4, x: 0, y: 0),
                                              atlasDepth: .depth4,
                                              cellSizePx: 256)
        return TileAtlasPlan(allocations: [allocation],
                              pageSummaries: [TileAtlasPageSummary(pageIndex: 0, allocatedSlotCount: 1)],
                              downgradedAllocationCount: 0,
                              skippedAllocationCount: 0)
    }

    private func makeTileBuffers() throws -> TileBuffers {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for MetalTile test fixture.")
        }
        let value: UInt32 = 0
        let buffer = device.makeBuffer(bytes: [value], length: MemoryLayout<UInt32>.stride)!
        let ground = TileBuffers.GeometryLayer(verticesBuffer: buffer,
                                               indicesBuffer: buffer,
                                               stylesBuffer: buffer,
                                               overviewStyleMaskBuffer: buffer,
                                               indicesCount: 0,
                                               verticesCount: 0)
        let extruded = TileBuffers.Extruded(verticesBuffer: buffer,
                                            indicesBuffer: buffer,
                                            stylesBuffer: buffer,
                                            indicesCount: 0,
                                            verticesCount: 0)
        let phases = RoadGeometryPhases(shadow: ground,
                                        casing: ground,
                                        fill: ground,
                                        detail: ground,
                                        overlay: ground)
        let roads = RoadStructureBuckets(tunnel: phases,
                                         ground: phases,
                                         bridge: phases)
        let emptyTextLabelSet = TileBuffers.TextLabelSet(placementInputs: [],
                                                         labelsByStyleRuns: [],
                                                         poiIconRuns: [])
        return TileBuffers(ground: ground,
                           roads: roads,
                           bridgeOverlay: ground,
                           extruded: extruded,
                           textLabels: TileBuffers.TextLabels(full: emptyTextLabelSet,
                                                               reduced: emptyTextLabelSet,
                                                               minimal: emptyTextLabelSet),
                           roadLabels: TileBuffers.RoadLabels(pathInputs: [],
                                                              pathRanges: [],
                                                              pathLabels: [],
                                                              labelStyle: nil,
                                                              localGlyphVerticesBuffer: nil,
                                                              localGlyphVertexCount: 0,
                                                              glyphBounds: [],
                                                              glyphBoundRanges: [],
                                                              sizes: [],
                                                              anchorRanges: [],
                                                              anchors: []))
    }
}
