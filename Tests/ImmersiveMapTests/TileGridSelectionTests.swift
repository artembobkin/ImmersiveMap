// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The tile grid's side of a tap, its texts and the patch its tiles are
/// drawn with.
@MainActor
final class TileGridSelectionTests: XCTestCase {
    func testATileSurvivesTheObjectID() {
        for tile in [Tile(x: 0, y: 0, z: 0), Tile(x: 19295, y: 24641, z: 15),
                     Tile(x: (1 << 24) - 1, y: (1 << 24) - 1, z: 24)] {
            XCTAssertEqual(TileGridSelection.tile(ofObjectID: TileGridSelection.objectID(of: tile)), tile)
        }
    }

    func testAFrameThatShowedNoGridTakesNoTap() {
        XCTAssertNil(TileGridSelectionSnapshot.empty.hitTest(point: CGPoint(x: 10, y: 10)))
        let runtime = ImmersiveMapTileGridRuntime()
        let selection = TileGridSelection(source: runtime)
        XCTAssertNil(selection.hitTest(at: CGPoint(x: 10, y: 10), contentsScale: 2), "No controller, no grid")
        XCTAssertTrue(selection.owns(.tileGrid))
        XCTAssertFalse(selection.contains(ImmersiveMapSelection(kind: .tileGrid, objectID: 1)),
                       "A tile is never the map's single selection")
    }

    /// A feature that takes every tap at `point`.
    private final class StubFeature: SelectableMapFeature {
        let kind: ImmersiveMapSelection.Kind
        let point: CGPoint?
        let isSelectable: Bool
        let clearsSelectionOnTap: Bool
        let tapKind: MapTapKind
        var claimsItsTapKind: Bool { tapKind != .single }
        var taps = 0

        init(kind: String, point: CGPoint?, isSelectable: Bool, clearsSelectionOnTap: Bool,
             tapKind: MapTapKind = .single) {
            self.tapKind = tapKind
            self.kind = ImmersiveMapSelection.Kind(rawValue: kind)
            self.point = point
            self.isSelectable = isSelectable
            self.clearsSelectionOnTap = clearsSelectionOnTap
        }

        func owns(_ kind: ImmersiveMapSelection.Kind) -> Bool { kind == self.kind }
        func updatePickData(_: any SelectionPickData) {}
        func resetPickData() {}
        func hitTest(at point: CGPoint, contentsScale _: CGFloat) -> SelectionHit? {
            guard self.point == nil || self.point == point else { return nil }
            return SelectionHit(ImmersiveMapSelection(kind: kind, objectID: 1))
        }
        func contains(_: ImmersiveMapSelection) -> Bool { isSelectable }
        func deliverTap(_: SelectionHit, at _: CGPoint) -> Bool {
            taps += 1
            return true
        }
    }

    private func makeHandler(_ features: [any SelectableMapFeature]) -> ImmersiveMapSelectionHandler {
        let renderRuntime = ImmersiveMapRenderRuntime(configuration: ImmersiveMapSettings.default.renderLoop)
        return ImmersiveMapSelectionHandler(
            host: ImmersiveMapSelectionHost(viewportRuntime: ImmersiveMapViewportRuntime(), renderRuntime: renderRuntime),
            features: features)
    }

    func testAFeatureIsAskedOnlyAboutItsOwnGesture() {
        let object = StubFeature(kind: "object", point: CGPoint(x: 5, y: 5), isSelectable: true,
                                 clearsSelectionOnTap: false)
        let ground = StubFeature(kind: "ground", point: nil, isSelectable: false, clearsSelectionOnTap: true,
                                 tapKind: .double)
        let handler = makeHandler([object, ground])
        let controller = ImmersiveMapSelectionController()
        handler.syncController(controller)

        XCTAssertTrue(handler.isClaimed(.double), "The double tap is the grid's, not the zoom's")
        XCTAssertFalse(handler.isClaimed(.secondary))
        XCTAssertEqual(handler.handleMapTap(at: CGPoint(x: 50, y: 50)), .background,
                       "A single tap passes a grid picked by the double tap")
        XCTAssertEqual(ground.taps, 0)

        XCTAssertEqual(handler.handleMapTap(at: CGPoint(x: 5, y: 5)), .consumed)
        XCTAssertNotNil(controller.currentSelection())
        XCTAssertEqual(handler.handleMapTap(at: CGPoint(x: 5, y: 5), kind: .secondary), .background)
        XCTAssertNotNil(controller.currentSelection(), "A gesture that lands on nothing is no tap on the bare map")
        XCTAssertEqual(handler.handleMapTap(at: CGPoint(x: 5, y: 5), kind: .double), .consumed)
        XCTAssertEqual(ground.taps, 1)
        XCTAssertEqual(object.taps, 1, "The object is not asked about the double tap")
    }

    func testATapOnTheGridEndsTheMapsSelection() {
        let object = StubFeature(kind: "object", point: CGPoint(x: 5, y: 5), isSelectable: true,
                                 clearsSelectionOnTap: false)
        let ground = StubFeature(kind: "ground", point: nil, isSelectable: false, clearsSelectionOnTap: true)
        let renderRuntime = ImmersiveMapRenderRuntime(configuration: ImmersiveMapSettings.default.renderLoop)
        let handler = ImmersiveMapSelectionHandler(
            host: ImmersiveMapSelectionHost(viewportRuntime: ImmersiveMapViewportRuntime(), renderRuntime: renderRuntime),
            features: [object, ground])
        let controller = ImmersiveMapSelectionController()
        handler.syncController(controller)

        XCTAssertEqual(handler.handleMapTap(at: CGPoint(x: 5, y: 5)), .consumed)
        XCTAssertEqual(controller.currentSelection()?.kind, object.kind)
        XCTAssertEqual(handler.handleMapTap(at: CGPoint(x: 50, y: 50)), .consumed, "The grid takes the tap")
        XCTAssertNil(controller.currentSelection(), "And the object is a tap away from deselected")
    }

    // MARK: - The texts

    func testTheTextOfATile() {
        let tile = Tile(x: 19295, y: 24641, z: 15)
        XCTAssertEqual(TileGridLabels.text(for: tile, format: .zxy, provider: nil), "15/19295/24641")
        XCTAssertEqual(TileGridLabels.text(for: tile, format: .xyz, provider: nil), "19295/24641/15")
        XCTAssertNil(TileGridLabels.text(for: tile, format: .hidden, provider: nil))
        XCTAssertEqual(TileGridLabels.text(for: tile, format: .hidden, provider: { "\($0.zoom)!" }), "15!",
                       "The app's text takes the format's place")
        XCTAssertNil(TileGridLabels.text(for: tile, format: .zxy, provider: { _ in nil }))
        XCTAssertNil(TileGridLabels.text(for: tile, format: .zxy, provider: { _ in "" }))
    }

    func testTheTextIsSizedToTheTile() {
        XCTAssertEqual(TileGridLabels.tileSharePerEm(widthEm: 7, heightEm: 1, widthShare: 0.7, heightShare: 0.2), 0.1,
                       accuracy: 1e-6, "A long text is held by the width")
        XCTAssertEqual(TileGridLabels.tileSharePerEm(widthEm: 1, heightEm: 1, widthShare: 0.7, heightShare: 0.2), 0.2,
                       accuracy: 1e-6, "A short one by the height")
        XCTAssertEqual(TileGridLabels.tileSharePerEm(widthEm: 0, heightEm: 1, widthShare: 0.7, heightShare: 0.2), 0)
    }

    func testTheGlyphsStandRoundTheMiddleOfTheirTile() {
        var laidOut = 0
        // One glyph two ems wide and one tall, its box at the origin.
        let labels = TileGridLabels { _ in
            laidOut += 1
            let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(2, 0), SIMD2(0, 1), SIMD2(2, 0), SIMD2(2, 1), SIMD2(0, 1)]
            return TextMetrics(size: TextSize(width: 2, height: 1),
                               vertices: corners.map { LabelVertex(position: $0, uv: $0, labelIndex: 0) })
        }
        let settings = ImmersiveMapSettings.TileGridSettings(labelMaximumWidthShare: 0.5, labelMaximumHeightShare: 1)
        let content = TileGridContent(selectedTiles: [], labelRevision: 0, labelProvider: { _ in "same" })
        let tiles = [VisibleTile(x: 0, y: 0, z: 1), VisibleTile(x: 1, y: 0, z: 1)]
        let glyphs = labels.glyphs(for: tiles, settings: settings, content: content, minimumTilePx: 200)

        XCTAssertEqual(glyphs.count, 12)
        XCTAssertEqual(laidOut, 1, "A text is laid out once however many tiles carry it")
        XCTAssertEqual(glyphs.prefix(6).map(\.tileIndex), Array(repeating: 0, count: 6))
        XCTAssertEqual(glyphs.suffix(6).map(\.tileIndex), Array(repeating: 1, count: 6))
        // Half the tile's width, a quarter of its height, the text's
        // bottom toward the south.
        XCTAssertEqual(glyphs[0].tileUV, SIMD2(0.25, 0.625))
        XCTAssertEqual(glyphs[4].tileUV, SIMD2(0.75, 0.375))
        XCTAssertEqual(glyphs[0].minimumEmPx, 50, accuracy: 1e-4)

        _ = labels.glyphs(for: tiles, settings: settings,
                          content: TileGridContent(selectedTiles: [], labelRevision: 1, labelProvider: { _ in nil }),
                          minimumTilePx: 200)
        XCTAssertTrue(labels.glyphs(for: tiles, settings: settings,
                                    content: TileGridContent(selectedTiles: [], labelRevision: 1,
                                                             labelProvider: { _ in nil }),
                                    minimumTilePx: 200).isEmpty, "A new revision asks the provider again")
    }

    // MARK: - The patch

    func testThePatchIsCutFromTheOneLattice() {
        XCTAssertEqual(MemoryLayout<TileGridTileGPU>.stride, 32)
        XCTAssertEqual(MemoryLayout<TileGridGlyphGPU>.stride, 24)
        XCTAssertEqual(MemoryLayout<TileGridFrameUniform>.stride, 96)
        for subdivision in TileGridPipeline.subdivisions {
            let indices = TileGridPipeline.latticeIndices(subdivision: subdivision)
            XCTAssertEqual(indices.count, subdivision * subdivision * 6)
            XCTAssertEqual(indices.max(), 65 * 65 - 1, "Every patch reaches the lattice's last corner")
            XCTAssertEqual(indices.min(), 0)
        }
        XCTAssertEqual(TileGridPipeline.subdivision(zoom: 0, surface: .flat), 1)
        XCTAssertEqual(TileGridPipeline.subdivision(zoom: 0, surface: .sphere), 64)
        XCTAssertEqual(TileGridPipeline.subdivision(zoom: 2, surface: .morph), 16)
        XCTAssertEqual(TileGridPipeline.subdivision(zoom: 15, surface: .sphere), 4)
        for zoom in 0 ... ImmersiveMapTileID.maximumZoom {
            XCTAssertTrue(TileGridPipeline.subdivisions.contains(TileGridPipeline.subdivision(zoom: zoom, surface: .sphere)))
        }
    }
}
