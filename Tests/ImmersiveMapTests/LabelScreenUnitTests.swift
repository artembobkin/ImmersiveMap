// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Labels are sized in layout points and converted to device pixels once, at
/// the render boundary. These pin the two halves of that: the geometry a
/// prepared tile carries must not depend on the display, and the conversion
/// must scale everything the label occupies on screen together, so a denser
/// display shows the same map rather than a smaller one.
final class LabelScreenUnitTests: XCTestCase {
    func testScreenScaleConvertsPointsToPixels() {
        XCTAssertEqual(ScreenScale(pixelsPerPoint: 3).pixels(11), 33, accuracy: 0.0001)
        XCTAssertEqual(ScreenScale(pixelsPerPoint: 2).pixels(SIMD2<Float>(10, 20)),
                       SIMD2<Float>(20, 40))
        XCTAssertEqual(ScreenScale.reference.pixelsPerPoint, 2, accuracy: 0.0001)
        // A non-positive scale would collapse every label to a point.
        XCTAssertGreaterThan(ScreenScale(pixelsPerPoint: 0).pixelsPerPoint, 0)
        XCTAssertGreaterThan(ScreenScale(pixelsPerPoint: -4).pixelsPerPoint, 0)
    }

    func testGlyphGeometryIsBakedInPointsAndIsDisplayIndependent() throws {
        let builder = try makeTextLabelsBuilder()
        let style = makeStyle(sizePoints: 12)
        let labels = builder.build(textLabels: [makeTextLabel(text: "Point", style: style)],
                                   tile: Tile(x: 0, y: 0, z: 12))
        let size = try XCTUnwrap(labels.full.placementInputs.first).placementMeta.labelSizePoints

        // The bake knows nothing about a display, so the box is the em size
        // times the font's metrics, in points. A 12 point label is roughly a
        // line high, never the 24 or 36 pixels a 2x or 3x display would give it.
        XCTAssertGreaterThan(size.y, 8)
        XCTAssertLessThan(size.y, 20)

        // And the pixels it covers follow the display, in step.
        let atTwoX = ScreenScale(pixelsPerPoint: 2).pixels(size)
        let atThreeX = ScreenScale(pixelsPerPoint: 3).pixels(size)
        XCTAssertEqual(atThreeX.x / atTwoX.x, 1.5, accuracy: 0.0001)
        XCTAssertEqual(atThreeX.y / atTwoX.y, 1.5, accuracy: 0.0001)
    }

    func testGlyphGeometryScalesWithTheStyleSize() throws {
        let builder = try makeTextLabelsBuilder()
        let small = try labelSizePoints(builder: builder, sizePoints: 11)
        let large = try labelSizePoints(builder: builder, sizePoints: 22)

        XCTAssertEqual(large.x / small.x, 2.0, accuracy: 0.01)
        XCTAssertEqual(large.y / small.y, 2.0, accuracy: 0.01)
    }

    func testHaloWidthTracksBothTheEmSizeAndTheDisplay() {
        let style = makeStyle(sizePoints: 11, haloEm: 0.15)

        XCTAssertEqual(style.haloWidthPixels(screenScale: ScreenScale(pixelsPerPoint: 2)),
                       11 * 0.15 * 2,
                       accuracy: 0.0001)
        XCTAssertEqual(style.haloWidthPixels(screenScale: ScreenScale(pixelsPerPoint: 3)),
                       11 * 0.15 * 3,
                       accuracy: 0.0001)

        // An em ratio is what stops the smallest labels carrying the widest halo
        // relative to their strokes: at a fixed ratio the halo shrinks with the text.
        let larger = makeStyle(sizePoints: 22, haloEm: 0.15)
        XCTAssertLessThan(style.haloWidthPixels(screenScale: .reference),
                          larger.haloWidthPixels(screenScale: .reference))
    }

    func testCollisionBoxesConvertToPixelsWithTheDisplay() {
        let candidate = ScreenCollisionCandidate(position: .zero,
                                                 halfSize: SIMD2<Float>(10, 4),
                                                 priority: 1,
                                                 secondaryPriority: 1,
                                                 isEnabled: true)
        let screenPoints = [ScreenPointOutput(position: SIMD2<Float>(40, 50),
                                              depth: 0.5,
                                              visible: 1,
                                              visibilityAlpha: 1)]

        func halfSize(at pixelsPerPoint: Float) -> SIMD2<Float> {
            BaseLabelVisibilityResolver.collisionCandidates(baseCandidates: [candidate],
                                                            screenPoints: screenPoints,
                                                            horizonVisibility: [true],
                                                            currentAlphas: [1],
                                                            minCameraZooms: [0],
                                                            cameraZoom: 14,
                                                            screenScale: ScreenScale(pixelsPerPoint: pixelsPerPoint))[0].halfSize
        }

        XCTAssertEqual(halfSize(at: 2), SIMD2<Float>(20, 8))
        XCTAssertEqual(halfSize(at: 3), SIMD2<Float>(30, 12))
    }

    /// A collision grid in device pixels would let a 3x phone pack 2.25 times as
    /// many labels into a physically smaller screen. In points the cell keeps
    /// the same perceived size, so density does not change with the display.
    func testCollisionGridCellIsExpressedInPoints() {
        let settings = ImmersiveMapSettings.default.labels
        XCTAssertEqual(settings.base.gridCellSizePoints, 16, accuracy: 0.0001)
        XCTAssertEqual(settings.road.gridCellSizePoints, 16, accuracy: 0.0001)
        XCTAssertEqual(ScreenScale(pixelsPerPoint: 2).pixels(settings.base.gridCellSizePoints), 32, accuracy: 0.0001)
        XCTAssertEqual(ScreenScale(pixelsPerPoint: 3).pixels(settings.base.gridCellSizePoints), 48, accuracy: 0.0001)
    }

    func testRoadLabelTileAreaThresholdIsExpressedInPoints() {
        // A tile square that just clears the threshold at 2x must also clear it
        // at 3x once the square grows with the display, and must fail at both
        // scales when it is smaller than the threshold in points.
        func keepsTile(sidePoints: Float, pixelsPerPoint: Float) -> Bool {
            let sidePixels = sidePoints * pixelsPerPoint
            let viewport = max(sidePixels * 2, 1000)
            return RoadLabelNearCameraFilter.shouldKeepTile(
                clipCorners: clipCorners(sidePixels: sidePixels, viewport: viewport),
                viewportWidth: viewport,
                viewportHeight: viewport,
                screenScale: ScreenScale(pixelsPerPoint: pixelsPerPoint)
            )
        }

        XCTAssertTrue(keepsTile(sidePoints: 200, pixelsPerPoint: 2))
        XCTAssertTrue(keepsTile(sidePoints: 200, pixelsPerPoint: 3))
        XCTAssertFalse(keepsTile(sidePoints: 100, pixelsPerPoint: 2))
        XCTAssertFalse(keepsTile(sidePoints: 100, pixelsPerPoint: 3))
    }

    /// The palette states the design curve and may dip under the floor; what
    /// must never reach the screen under it is a resolved style. This walks the
    /// classes whose curve is lowest, which are the ones the floor exists for.
    func testNoResolvedLabelStyleIsBelowTheReadableFloor() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault,
                                                     settings: ImmersiveMapSettings.default.style)
        let cases: [(String, String, [String: VectorTile_Tile.Value])] = [
            ("poi", "poi", ["class": stringValue("restaurant")]),
            ("house number", "housenumber", [:]),
            ("water", "water_name", [:]),
            ("ocean", "water_name", ["class": stringValue("ocean")]),
            ("village", "place", ["class": stringValue("village")]),
            ("city", "place", ["class": stringValue("city")]),
            ("state", "place", ["class": stringValue("state")])
        ]

        for (name, layerName, properties) in cases {
            let featureStyle = style.makeStyle(data: DetFeatureStyleData(layerName: layerName,
                                                                        properties: properties,
                                                                        tile: Tile(x: 0, y: 0, z: 16)))
            // Not `continue`: a case that stopped resolving would turn this into
            // a test that checks nothing and still reports green.
            guard let labelTextStyle = featureStyle.labelTextStyle else {
                XCTFail("\(name) no longer resolves to a label style")
                continue
            }
            XCTAssertGreaterThanOrEqual(labelTextStyle.sizePoints,
                                        LabelTypeScale.minimumSizePoints,
                                        "\(name) resolves below the readable floor")
            XCTAssertGreaterThan(labelTextStyle.haloEm, 0, "\(name) lost its halo")
        }
    }

    /// The floor belongs at the end of the pipeline. Applied to the base of a
    /// class instead, it would push everything derived from that base up too:
    /// an ocean label is the water appearance a few points larger, and lifting
    /// water first would make the ocean larger than the design asks for.
    func testTheFloorDoesNotPushDerivedClassesUp() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault,
                                                     settings: ImmersiveMapSettings.default.style)
        func sizePoints(class classValue: String?) -> Float {
            var properties: [String: VectorTile_Tile.Value] = [:]
            if let classValue {
                properties["class"] = stringValue(classValue)
            }
            let featureStyle = style.makeStyle(data: DetFeatureStyleData(layerName: "water_name",
                                                                        properties: properties,
                                                                        tile: Tile(x: 0, y: 0, z: 6)))
            return featureStyle.labelTextStyle?.sizePoints ?? -1
        }

        // Water is 9.5 by the curve and lands on the floor; the ocean variant is
        // three points above the curve, which clears the floor on its own.
        XCTAssertEqual(sizePoints(class: nil), LabelTypeScale.minimumSizePoints, accuracy: 0.0001)
        XCTAssertEqual(sizePoints(class: "ocean"), 12.5, accuracy: 0.0001)
    }

    private func stringValue(_ value: String) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.stringValue = value
        return tileValue
    }

    func testTypeScaleFloorRaisesUndersizedLabelsOnly() {
        XCTAssertEqual(LabelTypeScale.clamped(6), LabelTypeScale.minimumSizePoints)
        XCTAssertEqual(LabelTypeScale.clamped(20), 20)
        XCTAssertEqual(LabelTypeScale.minimumSizePoints, 11)
    }

    /// The shaders are where points become pixels. If a label shader ever stops
    /// applying the scale, labels silently render at reference size on every
    /// display, which is exactly the bug this unit exists to prevent.
    func testEveryLabelVertexShaderAppliesTheScale() throws {
        for relativePath in ["ImmersiveMap/Render/Labels/Shaders/Base/LabelTextVertex.metal",
                             "ImmersiveMap/Render/Labels/Shaders/POI/PoiSprite.metal",
                             "ImmersiveMap/Render/Labels/Shaders/Road/RoadLabelTextVertex.metal",
                             "ImmersiveMap/Render/Labels/Compute/Shaders/RoadLabelPlacement.metal"] {
            let source = try packageSource(relativePath: relativePath)
            XCTAssertTrue(source.contains("pixelsPerPoint"),
                          "\(relativePath) does not convert layout points to device pixels")
        }
    }

    func testExportPicksAScaleThatKeepsTheComposition() {
        // 1080p composes for the same point canvas a Retina display of that size
        // would give; 4K spends the extra resolution on detail instead of on map.
        XCTAssertEqual(ExportScreenScaleMath.pixelsPerPoint(forOutputSize: CGSize(width: 1920, height: 1080)),
                       2,
                       accuracy: 0.0001)
        XCTAssertEqual(ExportScreenScaleMath.pixelsPerPoint(forOutputSize: CGSize(width: 3840, height: 2160)),
                       4,
                       accuracy: 0.0001)
        // A 9:16 frame is measured on its short side, so a vertical export gets
        // the same label density as the landscape one.
        XCTAssertEqual(ExportScreenScaleMath.pixelsPerPoint(forOutputSize: CGSize(width: 1080, height: 1920)),
                       2,
                       accuracy: 0.0001)
        XCTAssertEqual(ExportScreenScaleMath.pixelsPerPoint(forOutputSize: CGSize(width: 320, height: 240)),
                       ExportScreenScaleMath.supportedRange.lowerBound,
                       accuracy: 0.0001)
        XCTAssertEqual(ExportScreenScaleMath.pixelsPerPoint(forOutputSize: .zero),
                       2,
                       accuracy: 0.0001)
    }

    // MARK: - Helpers

    /// The builder bakes through `TextRenderer`, which needs the compiled Metal
    /// library for its pipelines, so these two skip under `swift test` and run
    /// under the xcodebuild suite.
    private func makeTextLabelsBuilder() throws -> TileTextLabelsBuilder {
        let device = try MetalTestEnvironment.requireDevice()
        let library = try device.makeDefaultLibrary(bundle: .module)
        return TileTextLabelsBuilder(textRenderer: TextRenderer(device: device, library: library))
    }

    private func labelSizePoints(builder: TileTextLabelsBuilder,
                                 sizePoints: Float) throws -> SIMD2<Float> {
        let labels = builder.build(textLabels: [makeTextLabel(text: "Point",
                                                              style: makeStyle(sizePoints: sizePoints))],
                                   tile: Tile(x: 0, y: 0, z: 12))
        return try XCTUnwrap(labels.full.placementInputs.first).placementMeta.labelSizePoints
    }

    private func makeStyle(sizePoints: Float, haloEm: Float = 0.15) -> LabelTextStyle {
        LabelTextStyle(key: 7,
                       fillColor: SIMD3<Float>(0.1, 0.1, 0.1),
                       strokeColor: SIMD3<Float>(1, 1, 1),
                       haloEm: haloEm,
                       sizePoints: sizePoints,
                       weight: .thin)
    }

    private func makeTextLabel(text: String, style: LabelTextStyle) -> TileMvtParser.TextLabel {
        TileMvtParser.TextLabel(text: text,
                                position: SIMD2<Int16>(2048, 2048),
                                key: 1,
                                sortKey: 0,
                                collisionPriority: 0,
                                textStyle: style)
    }

    /// A screen-space square of `sidePixels`, expressed as clip-space corners of
    /// the viewport the filter projects into.
    private func clipCorners(sidePixels: Float, viewport: Float) -> [SIMD4<Float>] {
        let half = sidePixels / viewport
        return [
            SIMD4<Float>(-half, -half, 0, 1),
            SIMD4<Float>(half, -half, 0, 1),
            SIMD4<Float>(half, half, 0, 1),
            SIMD4<Float>(-half, half, 0, 1)
        ]
    }

    private func packageSource(relativePath: String) throws -> String {
        let packageRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRootURL.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
