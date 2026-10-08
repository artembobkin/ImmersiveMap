// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class ShadowPassGateResolverTests: XCTestCase {
    private static let state = ShadowFrameState(lightProjectionView: matrix_identity_float4x4,
                                                shadowUniform: .disabled,
                                                mapResolution: 2048)

    func testNilFrameStateGatesOff() {
        XCTAssertNil(ShadowPassGateResolver.resolve(shadowFrameState: nil,
                                                    hasBuildingCasters: true,
                                                    hasModelCasters: true))
    }

    func testNoCastersGatesOff() {
        XCTAssertNil(ShadowPassGateResolver.resolve(shadowFrameState: Self.state,
                                                    hasBuildingCasters: false,
                                                    hasModelCasters: false))
    }

    func testAnyCasterKindGatesOn() {
        XCTAssertNotNil(ShadowPassGateResolver.resolve(shadowFrameState: Self.state,
                                                       hasBuildingCasters: true,
                                                       hasModelCasters: false))
        XCTAssertNotNil(ShadowPassGateResolver.resolve(shadowFrameState: Self.state,
                                                       hasBuildingCasters: false,
                                                       hasModelCasters: true))
    }

    /// The buildings cast only where they draw: a frame that draws none
    /// (off the buildings' zoom, or every tile waiting for its model tile)
    /// runs no shadow pass for them, whatever the coverage planned.
    func testNoDrawnBuildingsHaveNoBuildingCasters() {
        XCTAssertTrue(ShadowMapReuseController.casterKeys(drawnPlacements: []).isEmpty)
        XCTAssertNil(ShadowPassGateResolver.resolve(shadowFrameState: Self.state,
                                                    hasBuildingCasters: false,
                                                    hasModelCasters: false))
    }
}
