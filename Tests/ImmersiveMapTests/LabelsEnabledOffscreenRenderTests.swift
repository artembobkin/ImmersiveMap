// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// `.labels(isEnabled:)` end to end: the same fixture tiles, carrying one
/// named peak, are fed to an engine with labels on and to one with labels
/// off. The first draws the label; the second, whose parser baked no text,
/// counts no label content, plans the label layer out, and paints the bare
/// ground. The switch is a parse-time decision, so it is two engines rather
/// than one flipped in place.
///
/// Requires the compiled Metal library, so it skips under `swift test` and runs
/// in the xcodebuild workspace suite.
final class LabelsEnabledOffscreenRenderTests: XCTestCase {
    private static let renderZoom = 14.0

    private static let camera = ImmersiveMapCameraPosition(latitudeDegrees: 55.75,
                                                           longitudeDegrees: 37.61,
                                                           zoom: renderZoom)

    @MainActor
    func testLabelsOffBakesNoTextAndPaintsTheBareGround() async throws {
        let labelled = try await renderPeak(labelsEnabled: true)
        XCTAssertGreaterThan(labelled.labelCount, 0,
                             "With labels on the named peak must reach the frame as a base label")
        XCTAssertFalse(labelled.skipReasons.contains(.noLabelContent),
                       "With a label on screen the label layer must be drawn")
        XCTAssertNotEqual(labelled.frame, labelled.bare, "The label must be in the picture")

        let unlabelled = try await renderPeak(labelsEnabled: false)
        XCTAssertEqual(unlabelled.labelCount, 0, "Labels off must bake and publish no label content")
        XCTAssertTrue(unlabelled.skipReasons.contains(.noLabelContent),
                      "Labels off must plan the label layer out of the frame")
        XCTAssertEqual(unlabelled.frame, unlabelled.bare, "Without labels the frame is the bare ground")
    }

    private struct PeakRender {
        let bare: RenderedFrame
        let frame: RenderedFrame
        let labelCount: Int
        let skipReasons: Set<RenderSkipReason>
    }

    @MainActor
    private func renderPeak(labelsEnabled: Bool) async throws -> PeakRender {
        let harness = try OffscreenFrameHarness.makeOrSkip(
            settings: ImmersiveMapSettings.default.labels(isEnabled: labelsEnabled))
        harness.setCameraPosition(Self.camera)
        let bare = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        try await loadPeakTiles(into: harness)
        // The labelled frame settles once the label's fade-in has finished
        // and the picture has moved away from the bare one. With labels off
        // nothing ever changes, so the wait is for two identical frames only.
        let frame = try await harness.renderUntilSettled(changedFrom: labelsEnabled ? bare : nil,
                                                         startingAt: OffscreenFrameHarness.frameTime(1))
        return PeakRender(bare: bare,
                          frame: frame,
                          labelCount: harness.engine.currentDiagnostics?.counterValue(.baseLabelCount) ?? 0,
                          skipReasons: harness.engine.currentDiagnostics?.skipReasons ?? [])
    }

    /// One named peak right under the camera in every tile of the
    /// neighbourhood that contains it (the frame is small, so a peak at a
    /// tile's centre could fall outside it): the peak layer includes any
    /// named feature at any zoom, so nothing but the switch decides whether
    /// it is baked. The other tiles carry the layer empty.
    @MainActor
    private func loadPeakTiles(into harness: OffscreenFrameHarness) async throws {
        let tiles = WebMercatorTileScheme.neighbourhoodPyramid(latitude: Self.camera.latitudeDegrees,
                                                               longitude: Self.camera.longitudeDegrees,
                                                               maximumZoom: Int(Self.renderZoom))
        for tile in tiles {
            let point = WebMercatorTileScheme.tileLocalPoint(latitude: Self.camera.latitudeDegrees,
                                                             longitude: Self.camera.longitudeDegrees,
                                                             in: tile)
            let containsCamera = (0..<4096).contains(point.0) && (0..<4096).contains(point.1)
            let peaks = containsCamera
                ? [VectorTileFixture.Feature(id: 1, geometry: .point(point.0, point.1), properties: ["name": "Peak", "rank": "1"])]
                : []
            let data = VectorTileFixture.layerTile(layerName: "mountain_peak", features: peaks)
            let didMaterialize = await harness.tileRenderStore.parseTile(tile: tile, data: data)
            XCTAssertTrue(didMaterialize,
                          "Fixture tile \(tile.z)/\(tile.x)/\(tile.y) must parse and reach the GPU")
        }
    }
}
