// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class MapboxDefaultMapStyleAdminLineTests: XCTestCase {
    func testAdminBoundaryLinesUseThickerWidths() {
        let style = MapboxDefaultMapStyle()
        let tile = Tile(x: 0, y: 0, z: 4)

        XCTAssertEqual(adminLineWidth(style: style, tile: tile, level: 1), 6)
        XCTAssertEqual(adminLineWidth(style: style, tile: tile, level: 2), 6)
        XCTAssertEqual(adminLineWidth(style: style, tile: tile, level: nil), 7.5)
    }

    private func adminLineWidth(style: MapboxDefaultMapStyle, tile: Tile, level: UInt64?) -> Double {
        var properties: [String: VectorTile_Tile.Value] = [:]
        if let level {
            var value = VectorTile_Tile.Value()
            value.uintValue = level
            properties["admin_level"] = value
        }

        let featureStyle = style.makeStyle(
            data: DetFeatureStyleData(layerName: "admin",
                                      properties: properties,
                                      tile: tile)
        )
        return featureStyle.parseGeometryStyleData.lineWidth
    }
}
