// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

final class RenderLoopPacingPowerConstraintsTests: XCTestCase {
    private func makePacing(interactionFramesPerSecond: Int = 120,
                            labelFadeFramesPerSecond: Int = 30) -> RenderLoopPacing {
        RenderLoopPacing(configuration: .init(forceContinuousRendering: false,
                                              interactionFramesPerSecond: interactionFramesPerSecond,
                                              labelFadeFramesPerSecond: labelFadeFramesPerSecond))
    }

    func testResolveMapsThermalStatesToCeilings() {
        XCTAssertEqual(RenderLoopPacing.PowerConstraints.resolve(thermalState: .nominal,
                                                                 isLowPowerModeEnabled: false),
                       .unconstrained)
        XCTAssertEqual(RenderLoopPacing.PowerConstraints.resolve(thermalState: .fair,
                                                                 isLowPowerModeEnabled: false),
                       .unconstrained)

        let serious = RenderLoopPacing.PowerConstraints.resolve(thermalState: .serious,
                                                                isLowPowerModeEnabled: false)
        XCTAssertEqual(serious.maximumFramesPerSecond, 60)
        XCTAssertFalse(serious.allowsProMotionHeadroom)

        let critical = RenderLoopPacing.PowerConstraints.resolve(thermalState: .critical,
                                                                 isLowPowerModeEnabled: false)
        XCTAssertEqual(critical.maximumFramesPerSecond, 30)
        XCTAssertFalse(critical.allowsProMotionHeadroom)
    }

    func testResolveLowPowerModeOnlyRevokesHeadroom() {
        let constraints = RenderLoopPacing.PowerConstraints.resolve(thermalState: .nominal,
                                                                    isLowPowerModeEnabled: true)
        XCTAssertNil(constraints.maximumFramesPerSecond)
        XCTAssertFalse(constraints.allowsProMotionHeadroom)
    }

    func testCeilingCapsInteractionAndLabelFadeRates() {
        let pacing = makePacing()
        pacing.setRenderingActivity(.interaction, isActive: true)
        XCTAssertEqual(pacing.targetFramesPerSecond, 120)

        pacing.applyPowerConstraints(.init(maximumFramesPerSecond: 60,
                                           allowsProMotionHeadroom: false))
        XCTAssertEqual(pacing.targetFramesPerSecond, 60)

        pacing.setRenderingActivity(.interaction, isActive: false)
        pacing.setRenderingActivity(.labelFade, isActive: true)
        pacing.applyPowerConstraints(.init(maximumFramesPerSecond: 15,
                                           allowsProMotionHeadroom: false))
        XCTAssertEqual(pacing.targetFramesPerSecond, 15)
    }

    func testConstraintsRevokeHeadroomAndUnconstrainedRestoresIt() {
        let pacing = makePacing()
        pacing.setRenderingActivity(.interaction, isActive: true)
        XCTAssertTrue(pacing.allowsFrameRateHeadroom)

        pacing.applyPowerConstraints(.init(maximumFramesPerSecond: nil,
                                           allowsProMotionHeadroom: false))
        XCTAssertFalse(pacing.allowsFrameRateHeadroom)

        pacing.applyPowerConstraints(.unconstrained)
        XCTAssertTrue(pacing.allowsFrameRateHeadroom)
    }

    func testCeilingLeavesIdleTargetAtZero() {
        let pacing = makePacing()
        pacing.applyPowerConstraints(.init(maximumFramesPerSecond: 30,
                                           allowsProMotionHeadroom: false))
        XCTAssertEqual(pacing.targetFramesPerSecond, 0)
    }
}
