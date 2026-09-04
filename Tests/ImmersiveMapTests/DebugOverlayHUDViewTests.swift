// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

@testable import ImmersiveMap
import UIKit
import XCTest

@MainActor
final class DebugOverlayHUDViewTests: XCTestCase {
    func testSurfaceModeControlInvokesCallback() {
        let view = DebugOverlayHUDView()
        var didRequestSurfaceSwitch = false
        view.onSurfaceModeSwitchRequested = {
            didRequestSurfaceSwitch = true
        }

        view.simulateSurfaceModeSwitchForTesting()

        XCTAssertTrue(didRequestSurfaceSwitch)
    }

    func testTileTraceControlInvokesCallbackAndReflectsSnapshot() {
        let view = DebugOverlayHUDView()
        let fileURL = URL(fileURLWithPath: "/tmp/immersive-map-tile-trace.jsonl")
        var didToggleRecording = false
        view.onTileTraceRecordingToggle = {
            didToggleRecording = true
        }

        view.apply(tileTraceSnapshot: TileTraceRecorderSnapshot(isRecording: true, fileURL: fileURL))
        view.simulateTileTraceRecordingToggleForTesting()

        XCTAssertTrue(didToggleRecording)
        XCTAssertEqual(view.tileTraceButtonTitleForTesting, "Stop recording")
        XCTAssertEqual(view.tileTraceStatusTextForTesting, "Recording: /tmp/immersive-map-tile-trace.jsonl")
    }

    func testTilesTabDisplaysTileTraceControl() {
        let view = DebugOverlayHUDView()
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: false,
                                                         wireframeEnabled: false,
                                                         roadLabelTilesEnabled: false))
        view.apply(snapshot: makeSnapshot(settings: settings))

        view.simulateTilesTabSelectionForTesting()
        view.layoutIfNeeded()

        XCTAssertTrue(view.isTileTraceControlVisibleForTesting)
    }

    func testBaseLabelsTraceControlInvokesCallbackAndReflectsSnapshot() {
        let view = DebugOverlayHUDView()
        let fileURL = URL(fileURLWithPath: "/tmp/immersive-map-base-label-trace.jsonl")
        var didToggleRecording = false
        view.onBaseLabelTraceRecordingToggle = {
            didToggleRecording = true
        }

        view.apply(baseLabelTraceSnapshot: BaseLabelTraceRecorderSnapshot(isRecording: true, fileURL: fileURL))
        view.simulateBaseLabelsTraceRecordingToggleForTesting()

        XCTAssertTrue(didToggleRecording)
        XCTAssertEqual(view.baseLabelTraceButtonTitleForTesting, "Stop recording")
        XCTAssertEqual(view.baseLabelTraceStatusTextForTesting, "Recording: /tmp/immersive-map-base-label-trace.jsonl")
        XCTAssertEqual(view.baseLabelTraceStatusTextColorForTesting, .white)
        XCTAssertEqual(view.baseLabelTraceStatusFontPointSizeForTesting, 15)
    }

    func testBaseLabelsTabDisplaysBaseLabelTraceControl() {
        let view = DebugOverlayHUDView()
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: false,
                                                         wireframeEnabled: false,
                                                         roadLabelTilesEnabled: false))
        view.apply(snapshot: makeSnapshot(settings: settings))

        view.simulateBaseLabelsTabSelectionForTesting()
        view.layoutIfNeeded()

        XCTAssertTrue(view.isBaseLabelTraceControlVisibleForTesting)
    }

    func testBaseLabelsTabDisplaysRoadLabelTilesControl() {
        let view = DebugOverlayHUDView()
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: false,
                                                         wireframeEnabled: false,
                                                         roadLabelTilesEnabled: true))
        view.apply(snapshot: makeSnapshot(settings: settings))

        view.simulateBaseLabelsTabSelectionForTesting()
        view.layoutIfNeeded()

        XCTAssertTrue(view.isRoadLabelTilesControlVisibleForTesting)
        XCTAssertTrue(view.isRoadLabelTilesSwitchOnForTesting)
    }

    func testRoadLabelTilesControlInvokesCallbackAndReflectsState() {
        let view = DebugOverlayHUDView()
        var didChange: Bool?
        view.onRoadLabelTilesEnabledChanged = { didChange = $0 }

        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: false,
                                                         wireframeEnabled: false,
                                                         roadLabelTilesEnabled: false))
        view.simulateBaseLabelsTabSelectionForTesting()
        view.layoutIfNeeded()
        view.simulateRoadLabelTilesSwitchChangeForTesting(true)

        XCTAssertEqual(didChange, true)
        XCTAssertTrue(view.isRoadLabelTilesSwitchOnForTesting)
    }

    func testControlsTabDisplaysDebugSwitchesWithoutStatsContent() {
        let view = DebugOverlayHUDView()
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: true,
                                                         wireframeEnabled: false,
                                                         roadLabelTilesEnabled: false))
        view.apply(snapshot: makeSnapshot(settings: settings))

        view.simulateControlsTabSelectionForTesting()
        view.layoutIfNeeded()

        XCTAssertTrue(view.isControlsTabSelectedForTesting)
        XCTAssertTrue(view.areDebugControlsVisibleForTesting)
        XCTAssertFalse(view.isStatsContentVisibleForTesting)
    }

    func testTileGridControlInvokesCallbackAndReflectsState() {
        let view = DebugOverlayHUDView()
        var didChange: Bool?
        view.onTileGridEnabledChanged = { didChange = $0 }

        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: false,
                                                         wireframeEnabled: false))
        view.simulateControlsTabSelectionForTesting()
        view.layoutIfNeeded()
        view.simulateTileGridSwitchChangeForTesting(true)

        XCTAssertEqual(didChange, true)
        XCTAssertTrue(view.isTileGridSwitchOnForTesting)
    }

    func testTileGridDensityControlInvokesCallbackAndReflectsState() {
        let view = DebugOverlayHUDView()
        var didChange: Int?
        view.onTileGridDensityChanged = { didChange = $0 }

        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: false,
                                                         wireframeEnabled: false))
        view.simulateControlsTabSelectionForTesting()
        view.layoutIfNeeded()

        XCTAssertEqual(view.tileGridDensityForTesting, DebugTileGridDensity.standard)

        view.simulateTileGridDensitySelectionForTesting(8)

        XCTAssertEqual(didChange, 8)
        XCTAssertEqual(view.tileGridDensityForTesting, 8)
    }

    func testTileGridControlReflectsAppliedSnapshot() {
        let view = DebugOverlayHUDView()

        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: false,
                                                         wireframeEnabled: false,
                                                         tileGridEnabled: true,
                                                         tileGridDensity: 2))

        XCTAssertTrue(view.isTileGridSwitchOnForTesting)
        XCTAssertEqual(view.tileGridDensityForTesting, 2)
    }

    func testTilesTabDisplaysTileLoadingStatusWithoutStatsContent() {
        let view = DebugOverlayHUDView()
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: true,
                                                         wireframeEnabled: false,
                                                         roadLabelTilesEnabled: false))
        view.apply(snapshot: DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: "z: 1.00", latLon: "lat: 0.000 lon: 0.000"),
            diagnosticsLines: [],
            tileLoadingStatusLines: [
                "network in:1 done:2 fail:0 bytes:1024",
                "parse in:1 done:1 fail:0",
                "current net:z4/1/1 parse:z4/2/1"
            ],
            tileLoadingStatusTiles: [
                TileLoadingStatusTileSnapshot(tile: Tile(x: 1, y: 1, z: 4),
                                              status: .loading,
                                              progress: 0.35,
                                              detail: "network"),
                TileLoadingStatusTileSnapshot(tile: Tile(x: 2, y: 1, z: 4),
                                              status: .ready,
                                              progress: 1,
                                              detail: "ready")
            ],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        ))

        view.simulateTilesTabSelectionForTesting()
        view.layoutIfNeeded()

        XCTAssertTrue(view.isTilesTabSelectedForTesting)
        XCTAssertTrue(view.isTilesContentVisibleForTesting)
        XCTAssertEqual(view.tilesStatusRowCountForTesting, 2)
        XCTAssertEqual(view.tilesStatusTextForTesting,
                       "network in:1 done:2 fail:0 bytes:1024\nparse in:1 done:1 fail:0\ncurrent net:z4/1/1 parse:z4/2/1\ntiles total: 2")
        XCTAssertFalse(view.isStatsContentVisibleForTesting)
    }

    func testTilesTabExpandsTilePreparationStagesAndParseLayers() {
        let view = DebugOverlayHUDView()
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let tile = Tile(x: 78, y: 39, z: 7)
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: true,
                                                         wireframeEnabled: false,
                                                         roadLabelTilesEnabled: false))
        view.apply(snapshot: DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: "z: 1.00", latLon: "lat: 0.000 lon: 0.000"),
            diagnosticsLines: [],
            tileLoadingStatusLines: [
                "network in:0 done:1 fail:0 bytes:1024",
                "parse in:0 done:1 fail:0"
            ],
            tileLoadingStatusTiles: [
                TileLoadingStatusTileSnapshot(
                    tile: tile,
                    status: .ready,
                    progress: 1,
                    detail: "ready",
                    preparationStages: [
                        TilePreparationStageSnapshot(name: "network", duration: 0.100),
                        TilePreparationStageSnapshot(name: "parse",
                                                     duration: 0.250,
                                                     layerTimings: [
                                                         TileParseLayerTiming(layerName: "land", duration: 0.127),
                                                         TileParseLayerTiming(layerName: "water_polygons", duration: 0.041),
                                                         TileParseLayerTiming(layerName: "streets", duration: 0.003)
                                                     ]),
                        TilePreparationStageSnapshot(name: "materialize", duration: 0.030),
                        TilePreparationStageSnapshot(name: "ready", duration: nil)
                    ])
            ],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        ))

        view.simulateTilesTabSelectionForTesting()
        view.layoutIfNeeded()
        view.simulateTilesStatusRowTapForTesting(at: 0)

        XCTAssertEqual(view.tilesStatusVisibleRowTextsForTesting, [
            "▾ z7/78/39 ready",
            "    network 100ms",
            "  ▸ parse 250ms",
            "    materialize 30ms",
            "    ready"
        ])

        view.simulateTilesStatusParseStageTapForTesting(tile: tile)

        XCTAssertEqual(view.tilesStatusVisibleRowTextsForTesting, [
            "▾ z7/78/39 ready",
            "    network 100ms",
            "  ▾ parse 250ms",
            "    land 127ms",
            "    water_polygons 41ms",
            "    streets 3ms",
            "    materialize 30ms",
            "    ready"
        ])
    }

    func testTilesTabCentersPrimaryTileTextInsideProgressBarAndUsesLargerFont() throws {
        let view = DebugOverlayHUDView()
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: true,
                                                         wireframeEnabled: false))
        view.apply(snapshot: DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: "z: 1.00", latLon: "lat: 0.000 lon: 0.000"),
            diagnosticsLines: [],
            tileLoadingStatusLines: [],
            tileLoadingStatusTiles: [
                TileLoadingStatusTileSnapshot(tile: Tile(x: 0, y: 0, z: 0),
                                              status: .ready,
                                              progress: 1,
                                              detail: "displayed")
            ],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        ))

        view.simulateTilesTabSelectionForTesting()
        view.layoutIfNeeded()

        let metrics = try XCTUnwrap(view.tilesStatusPrimaryRowMetricsForTesting)
        XCTAssertEqual(metrics.textRect.midY, metrics.progressBackgroundRect.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(metrics.fontSize, 13)
    }

    func testTilesStatusRowsUseFullBoundsWidthWhenRedrawnFromPartialDirtyRect() throws {
        let view = DebugOverlayHUDView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: true,
                                                         wireframeEnabled: false))
        view.apply(snapshot: DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: "z: 1.00", latLon: "lat: 0.000 lon: 0.000"),
            diagnosticsLines: [],
            tileLoadingStatusLines: [],
            tileLoadingStatusTiles: [
                TileLoadingStatusTileSnapshot(tile: Tile(x: 0, y: 0, z: 0),
                                              status: .ready,
                                              progress: 1,
                                              detail: "displayed")
            ],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        ))

        view.simulateTilesTabSelectionForTesting()
        view.layoutIfNeeded()

        let listView = try XCTUnwrap(findTilesStatusListView(in: view))
        let image = UIGraphicsImageRenderer(size: listView.bounds.size).image { _ in
            listView.draw(CGRect(x: 0, y: 0, width: 24, height: listView.bounds.height))
        }
        let rightEdgeProbeRect = CGRect(x: listView.bounds.width - 24,
                                        y: 2,
                                        width: 20,
                                        height: 24)

        XCTAssertGreaterThan(image.greenPixelCountForTesting(in: rightEdgeProbeRect, scale: 1), 0)
    }

    func testTilesTabDisplaysIdleMessageWhenStatusIsEmpty() {
        let view = DebugOverlayHUDView()
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: true,
                                                         wireframeEnabled: false))
        view.apply(snapshot: makeSnapshot(settings: settings))

        view.simulateTilesTabSelectionForTesting()
        view.layoutIfNeeded()

        XCTAssertEqual(view.tilesStatusTextForTesting, "tiles: idle\ntiles total: 0")
    }

    func testApplyingSameSnapshotDoesNotRebuildText() {
        let view = DebugOverlayHUDView()
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        let snapshot = makeSnapshot(settings: settings)

        view.apply(snapshot: snapshot)
        let firstUpdateCount = view.textUpdateCountForTesting

        view.apply(snapshot: snapshot)

        XCTAssertEqual(view.textUpdateCountForTesting, firstUpdateCount)
    }

    func testTilesTabKeepsPanelWidthStableWhenStatusTextChanges() {
        let view = DebugOverlayHUDView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: true,
                                                         wireframeEnabled: false))

        view.apply(snapshot: makeTileStatusSnapshot(settings: settings,
                                                    lines: ["network in:0 done:1 fail:0"]))
        view.simulateTilesTabSelectionForTesting()
        view.layoutIfNeeded()
        let shortStatusWidth = view.debugPanelFrameForTesting.width

        view.apply(snapshot: makeTileStatusSnapshot(settings: settings,
                                                    lines: [
                                                        "tiles req:2 dedup:2 active:2 scheduled:236",
                                                        "parse layers z7/74/36: water_polygons 30513ms, ocean 79ms, streets 24ms"
                                                    ]))
        view.layoutIfNeeded()

        XCTAssertEqual(view.debugPanelFrameForTesting.width, shortStatusWidth)
    }

    func testTilesTabScrollsWhenManyTileRowsAreVisible() {
        let view = DebugOverlayHUDView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        var settings = ImmersiveMapSettings.default.debug
        settings.enableDebugPanel = true
        view.apply(isDebugPanelEnabled: true,
                   controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                         tileLayersEnabled: true,
                                                         wireframeEnabled: false))
        view.apply(snapshot: DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: "z: 1.00", latLon: "lat: 0.000 lon: 0.000"),
            diagnosticsLines: [],
            tileLoadingStatusLines: [
                "network in:0 done:80 fail:0 bytes:1024",
                "parse in:0 done:80 fail:0"
            ],
            tileLoadingStatusTiles: (0..<80).map { index in
                TileLoadingStatusTileSnapshot(tile: Tile(x: index % 8, y: index / 8, z: 4),
                                              status: .ready,
                                              progress: 1,
                                              detail: "ready")
            },
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        ))

        view.simulateTilesTabSelectionForTesting()
        view.layoutIfNeeded()

        XCTAssertLessThanOrEqual(view.debugPanelFrameForTesting.maxY, view.bounds.maxY)
        XCTAssertTrue(view.isTilesScrollEnabledForTesting)
        XCTAssertEqual(view.tilesStatusRowCountForTesting, 80)
    }

    private func makeSnapshot(settings: ImmersiveMapSettings.DebugSettings) -> DebugOverlayHUDSnapshot {
        DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: "z: 1.00", latLon: "lat: 0.000 lon: 0.000"),
            diagnosticsLines: [],
            tileLoadingStatusLines: [],
            tileLoadingStatusTiles: [],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        )
    }

    private func makeTileStatusSnapshot(settings: ImmersiveMapSettings.DebugSettings,
                                        lines: [String]) -> DebugOverlayHUDSnapshot {
        DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: "z: 1.00", latLon: "lat: 0.000 lon: 0.000"),
            diagnosticsLines: [],
            tileLoadingStatusLines: lines,
            tileLoadingStatusTiles: [],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        )
    }

    private func findTilesStatusListView(in view: UIView) -> UIView? {
        if String(describing: type(of: view)) == "DebugOverlayTilesStatusListView" {
            return view
        }

        for subview in view.subviews {
            if let match = findTilesStatusListView(in: subview) {
                return match
            }
        }
        return nil
    }
}

private extension UIImage {
    func greenPixelCountForTesting(in rect: CGRect, scale: CGFloat) -> Int {
        guard let cgImage else { return 0 }
        return pixelCountForTesting(in: rect, scale: scale) { red, green, blue, alpha in
            alpha > 120
                && green > 120
                && Int(green) > Int(red) + 20
                && Int(green) > Int(blue) + 20
        }
    }

    private func pixelCountForTesting(in rect: CGRect,
                                      scale: CGFloat,
                                      predicate: (UInt8, UInt8, UInt8, UInt8) -> Bool) -> Int {
        guard let cgImage else { return 0 }
        let imageRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let pixelRect = CGRect(x: rect.minX * scale,
                               y: rect.minY * scale,
                               width: rect.width * scale,
                               height: rect.height * scale)
            .integral
            .intersection(imageRect)
        guard pixelRect.isEmpty == false else { return 0 }

        let width = Int(pixelRect.width)
        let height = Int(pixelRect.height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        return pixels.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return 0
            }

            context.translateBy(x: -pixelRect.minX, y: CGFloat(cgImage.height) - pixelRect.minY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

            var count = 0
            for offset in stride(from: 0, to: buffer.count, by: bytesPerPixel) {
                let red = buffer[offset]
                let green = buffer[offset + 1]
                let blue = buffer[offset + 2]
                let alpha = buffer[offset + 3]
                if predicate(red, green, blue, alpha) {
                    count += 1
                }
            }
            return count
        }
    }
}

#endif
