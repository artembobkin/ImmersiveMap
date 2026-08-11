// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

final class RenderLoopPacingPowerConstraintStateTests: XCTestCase {
    private func makePacing(interactionFramesPerSecond: Int = 120,
                            labelFadeFramesPerSecond: Int = 30) -> RenderLoopPacing {
        RenderLoopPacing(configuration: .init(forceContinuousRendering: false,
                                              interactionFramesPerSecond: interactionFramesPerSecond,
                                              labelFadeFramesPerSecond: labelFadeFramesPerSecond))
    }

    func testResolveMapsThermalStatesToCeilings() {
        XCTAssertEqual(RenderLoopPacing.PowerConstraintState.resolve(thermalState: .nominal,
                                                                 isLowPowerModeEnabled: false),
                       .unconstrained)
        XCTAssertEqual(RenderLoopPacing.PowerConstraintState.resolve(thermalState: .fair,
                                                                 isLowPowerModeEnabled: false),
                       .unconstrained)

        let serious = RenderLoopPacing.PowerConstraintState.resolve(thermalState: .serious,
                                                                isLowPowerModeEnabled: false)
        XCTAssertEqual(serious.maximumFramesPerSecond, 60)
        XCTAssertFalse(serious.allowsProMotionHeadroom)

        let critical = RenderLoopPacing.PowerConstraintState.resolve(thermalState: .critical,
                                                                 isLowPowerModeEnabled: false)
        XCTAssertEqual(critical.maximumFramesPerSecond, 30)
        XCTAssertFalse(critical.allowsProMotionHeadroom)
    }

    func testResolveLowPowerModeOnlyRevokesHeadroom() {
        let constraints = RenderLoopPacing.PowerConstraintState.resolve(thermalState: .nominal,
                                                                    isLowPowerModeEnabled: true)
        XCTAssertNil(constraints.maximumFramesPerSecond)
        XCTAssertFalse(constraints.allowsProMotionHeadroom)
    }

    func testCeilingCapsInteractionAndLabelFadeRates() {
        let pacing = makePacing()
        pacing.setRenderingActivity(.interaction, isActive: true)
        XCTAssertEqual(pacing.targetFramesPerSecond, 120)

        pacing.applyPowerConstraintState(.init(maximumFramesPerSecond: 60,
                                           allowsProMotionHeadroom: false))
        XCTAssertEqual(pacing.targetFramesPerSecond, 60)

        pacing.setRenderingActivity(.interaction, isActive: false)
        pacing.setRenderingActivity(.labelFade, isActive: true)
        pacing.applyPowerConstraintState(.init(maximumFramesPerSecond: 15,
                                           allowsProMotionHeadroom: false))
        XCTAssertEqual(pacing.targetFramesPerSecond, 15)
    }

    func testConstraintsRevokeHeadroomAndUnconstrainedRestoresIt() {
        let pacing = makePacing()
        pacing.setRenderingActivity(.interaction, isActive: true)
        XCTAssertTrue(pacing.allowsFrameRateHeadroom)

        pacing.applyPowerConstraintState(.init(maximumFramesPerSecond: nil,
                                           allowsProMotionHeadroom: false))
        XCTAssertFalse(pacing.allowsFrameRateHeadroom)

        pacing.applyPowerConstraintState(.unconstrained)
        XCTAssertTrue(pacing.allowsFrameRateHeadroom)
    }

    func testCeilingLeavesIdleTargetAtZero() {
        let pacing = makePacing()
        pacing.applyPowerConstraintState(.init(maximumFramesPerSecond: 30,
                                           allowsProMotionHeadroom: false))
        XCTAssertEqual(pacing.targetFramesPerSecond, 0)
    }
}
