// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A parked view has nothing to present into: pacing must gate off every
/// rendering reason (pending one-shot requests, activities, even
/// forceContinuousRendering) and hand them back on adoption.
final class RenderLoopPacingParkedTests: XCTestCase {
    func testParkedPacingPausesDespitePendingWork() {
        let pacing = RenderLoopPacing(configuration: ImmersiveMapSettings.default.renderLoop)
        pacing.requestOneFrame(reason: .tileAvailable)
        pacing.setRenderingActivity(.labelFade, isActive: true)
        XCTAssertTrue(pacing.needsFrameRendering)

        pacing.setParked(true)

        XCTAssertFalse(pacing.needsFrameRendering)
        XCTAssertTrue(pacing.shouldPauseDisplayLink)
    }

    func testParkedPacingOverridesForceContinuousRendering() {
        var configuration = ImmersiveMapSettings.default.renderLoop
        configuration.forceContinuousRendering = true
        let pacing = RenderLoopPacing(configuration: configuration)
        XCTAssertTrue(pacing.needsFrameRendering)

        pacing.setParked(true)

        XCTAssertFalse(pacing.needsFrameRendering)
    }

    func testAccumulatedWorkResumesOnAdoption() {
        let pacing = RenderLoopPacing(configuration: ImmersiveMapSettings.default.renderLoop)
        pacing.setParked(true)
        pacing.requestOneFrame(reason: .tileAvailable)
        pacing.setRenderingActivity(.labelFade, isActive: true)
        XCTAssertFalse(pacing.needsFrameRendering)

        pacing.setParked(false)

        XCTAssertTrue(pacing.needsFrameRendering)
    }
}
