// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
@testable import ImmersiveMapDebug
import XCTest

/// The labels' opacity by the zoom (`ImmersiveMapLabelOpacity`): read at a
/// zoom into the two factors of a frame, held to 0...1, the POIs' for a
/// POI's plate and name and the names' for every other label, over the
/// label's own opacity.
final class ImmersiveMapLabelOpacityTests: XCTestCase {
    func testTheDefaultLeavesEveryLabelAtItsOwnOpacity() {
        let frame = ImmersiveMapLabelOpacity().frame(atZoom: 12)
        XCTAssertEqual(frame, .solid)
        XCTAssertEqual(ProtomapsBasemapTheme.default.labelOpacity, ImmersiveMapLabelOpacity())
    }

    func testTheCurvesAreReadAtTheZoomAndHeldToTheUnitRange() {
        let opacity = ImmersiveMapLabelOpacity(names: [2: 1, 6: 0.4], pois: [14: 1.5, 16: -0.2])
        XCTAssertEqual(opacity.frame(atZoom: 1).names, 1)
        XCTAssertEqual(opacity.frame(atZoom: 8).names, 0.4, accuracy: 1e-6)
        XCTAssertEqual(opacity.frame(atZoom: 10).pois, 1, "above one is held to one")
        XCTAssertEqual(opacity.frame(atZoom: 18).pois, 0, "below zero is held to zero")
    }

    func testAPoiTakesThePoisFactorAndEveryOtherLabelTheNames() {
        let frame = LabelOpacityFrame(names: 0.5, pois: 0.25)
        let name = LabelTextStyle(fillColor: .zero, strokeColor: .one, haloEm: 0.1, sizePoints: 12,
                                  weight: .bold, opacity: 0.8)
        let poi = LabelTextStyle(fillColor: .zero, strokeColor: .one, haloEm: 0.1, sizePoints: 12,
                                 weight: .thin, opacity: 0.8, isPointOfInterest: true)
        XCTAssertEqual(frame.opacity(of: name), 0.4, accuracy: 1e-6)
        XCTAssertEqual(frame.opacity(of: poi), 0.2, accuracy: 1e-6)
    }

    /// The POI plate's style is laid out alike in Swift and in Metal
    /// (PoiSprite.metal): the opacity after the two colours.
    func testThePoiPlateStyleMatchesTheShader() throws {
        XCTAssertEqual(MemoryLayout<PoiIconStyleUniform>.stride, 48)
        XCTAssertEqual(MemoryLayout<PoiIconStyleUniform>.offset(of: \.opacity), 32)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ImmersiveMap/Labels/Shaders/POI/PoiSprite.metal")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct PoiIconStyle {"))
        let body = String(source[start.upperBound...].prefix { $0 != "}" })
        var fields: [String] = []
        for line in body.split(separator: "\n") {
            let code = String(line.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty == false {
                fields.append(trimmed)
            }
        }
        XCTAssertEqual(fields, ["float4 backgroundColor;", "float4 iconColor;", "float opacity;"])
    }

    /// The export writes the dragged curves as the built-in style with them,
    /// and nothing when the panel has not touched them.
    func testTheExportWritesTheDraggedCurvesAsTheBuiltInStyle() {
        let opacity = ImmersiveMapLabelOpacity(names: [2: 1, 6: 0.5], pois: 0.7)
        let line = DebugOverlaySettingsExport.labelOpacityModifier(opacity)
        XCTAssertTrue(line.hasPrefix(".mapStyle(ProtomapsBasemapMapStyle.default.apply { $0.labelOpacity = "))
        XCTAssertTrue(line.contains("names: "))
        XCTAssertTrue(line.contains("pois: "))

        let without = DebugOverlaySettingsExport.swiftCode(settings: .default, date: Date(), cameraLines: [])
        XCTAssertFalse(without.contains("labelOpacity"))
        let with = DebugOverlaySettingsExport.swiftCode(settings: .default, date: Date(), cameraLines: [],
                                                        labelOpacity: opacity)
        XCTAssertTrue(with.contains(line))
    }
}
