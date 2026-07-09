// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class RenderTerrainAvailabilityTests: XCTestCase {
    func testAvailabilityBuilderDefaultsTerrainDisabled() {
        let availability = RenderPassAvailabilityBuilder(renderSurfaceMode: .flat).build()

        XCTAssertFalse(availability.terrainEnabled)
    }

    func testRenderPassGraphClassifiesTerrainAsWorldLayer() {
        XCTAssertTrue(RenderPassGraph.isWorldLayer(.terrain))
        XCTAssertFalse(RenderPassGraph.isOverlayLayer(.terrain))
    }

    func testTerrainAvailabilityRequiresSettingsSourceAndDebugControl() {
        let enabledSettings = ImmersiveMapSettings.default
            .terrainSource(.reEarth())
            .terrainRendering(isEnabled: true)

        XCTAssertTrue(
            RenderTerrainAvailabilityPolicy.shouldRender(
                settings: enabledSettings,
                controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                      tileLayersEnabled: false,
                                                      wireframeEnabled: false,
                                                      terrainEnabled: true)
            )
        )

        XCTAssertFalse(
            RenderTerrainAvailabilityPolicy.shouldRender(
                settings: enabledSettings.terrainRendering(isEnabled: false),
                controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                      tileLayersEnabled: false,
                                                      wireframeEnabled: false,
                                                      terrainEnabled: true)
            )
        )
        XCTAssertFalse(
            RenderTerrainAvailabilityPolicy.shouldRender(
                settings: ImmersiveMapSettings.default.terrainRendering(isEnabled: true),
                controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                      tileLayersEnabled: false,
                                                      wireframeEnabled: false,
                                                      terrainEnabled: true)
            )
        )
        XCTAssertFalse(
            RenderTerrainAvailabilityPolicy.shouldRender(
                settings: enabledSettings,
                controls: DebugOverlayControlSnapshot(axesEnabled: false,
                                                      tileLayersEnabled: false,
                                                      wireframeEnabled: false,
                                                      terrainEnabled: false)
            )
        )
    }
}
