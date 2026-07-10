// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class RenderFrameOutputPlannerTests: XCTestCase {
    func testDisabledFXAARendersDirectlyToDrawableWithoutPostProcessingPass() {
        let plan = RenderFrameOutputPlanner.plan(fxaaEnabled: false,
                                                 renderSampleCount: 1)

        XCTAssertEqual(plan.worldColorDestination, .drawable)
        XCTAssertFalse(plan.usesMultisampleResolve)
        XCTAssertFalse(plan.includesPostProcessingPass)
    }

    func testDisabledFXAAResolvesMSAADirectlyToDrawableWithoutPostProcessingPass() {
        let plan = RenderFrameOutputPlanner.plan(fxaaEnabled: false,
                                                 renderSampleCount: 4)

        XCTAssertEqual(plan.worldColorDestination, .drawable)
        XCTAssertTrue(plan.usesMultisampleResolve)
        XCTAssertFalse(plan.includesPostProcessingPass)
    }

    func testEnabledFXAARendersIntoPostProcessingInputAndAddsPass() {
        let plan = RenderFrameOutputPlanner.plan(fxaaEnabled: true,
                                                 renderSampleCount: 1)

        XCTAssertEqual(plan.worldColorDestination, .postProcessingInput)
        XCTAssertFalse(plan.usesMultisampleResolve)
        XCTAssertTrue(plan.includesPostProcessingPass)
    }

    func testEnabledFXAAResolvesMSAAIntoPostProcessingInputAndAddsPass() {
        let plan = RenderFrameOutputPlanner.plan(fxaaEnabled: true,
                                                 renderSampleCount: 4)

        XCTAssertEqual(plan.worldColorDestination, .postProcessingInput)
        XCTAssertTrue(plan.usesMultisampleResolve)
        XCTAssertTrue(plan.includesPostProcessingPass)
    }

    func testPlannerRespondsToLiveFXAAToggleWithoutRetainingPreviousDecision() {
        let enabledPlan = RenderFrameOutputPlanner.plan(fxaaEnabled: true,
                                                        renderSampleCount: 4)
        let disabledPlan = RenderFrameOutputPlanner.plan(fxaaEnabled: false,
                                                         renderSampleCount: 4)

        XCTAssertEqual(enabledPlan.worldColorDestination, .postProcessingInput)
        XCTAssertTrue(enabledPlan.includesPostProcessingPass)
        XCTAssertEqual(disabledPlan.worldColorDestination, .drawable)
        XCTAssertFalse(disabledPlan.includesPostProcessingPass)
    }
}
