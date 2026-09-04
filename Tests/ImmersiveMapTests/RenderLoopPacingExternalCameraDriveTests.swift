// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A camera position set from outside (`ImmersiveMapCameraController.jump`)
/// keeps the render loop awake for a grace period at the interaction frame
/// rate, so an app driving the camera once per frame never pauses and resumes
/// the display link between two frames, while a lone jump still lets the link
/// pause once the grace has passed.
final class RenderLoopPacingExternalCameraDriveTests: XCTestCase {
    private let grace = RenderLoopPacing.externalCameraDriveGraceSeconds

    func testJumpKeepsTheLoopAwakeAtTheInteractionRate() {
        let configuration = ImmersiveMapSettings.default.renderLoop
        let pacing = RenderLoopPacing(configuration: configuration)
        XCTAssertTrue(pacing.shouldPauseDisplayLink)

        pacing.noteExternalCameraDrive(at: 10)

        XCTAssertTrue(pacing.needsFrameRendering)
        XCTAssertFalse(pacing.shouldPauseDisplayLink)
        XCTAssertEqual(pacing.targetFramesPerSecond, configuration.interactionFramesPerSecond)
        XCTAssertTrue(pacing.allowsFrameRateHeadroom)
    }

    func testTheDriveExpiresOnceItsGraceHasPassed() {
        let pacing = RenderLoopPacing(configuration: ImmersiveMapSettings.default.renderLoop)
        pacing.noteExternalCameraDrive(at: 10)

        pacing.expireExternalCameraDrive(at: 10 + grace / 2)
        XCTAssertTrue(pacing.needsFrameRendering, "still inside the grace")

        pacing.expireExternalCameraDrive(at: 10 + grace)
        XCTAssertFalse(pacing.needsFrameRendering)
        XCTAssertTrue(pacing.shouldPauseDisplayLink)
    }

    func testConsecutiveJumpsPushTheDeadline() {
        let pacing = RenderLoopPacing(configuration: ImmersiveMapSettings.default.renderLoop)
        pacing.noteExternalCameraDrive(at: 10)
        pacing.expireExternalCameraDrive(at: 10 + grace * 0.8)
        pacing.noteExternalCameraDrive(at: 10 + grace * 0.8)

        pacing.expireExternalCameraDrive(at: 10 + grace * 1.5)
        XCTAssertTrue(pacing.needsFrameRendering, "the second jump extended the grace")

        pacing.expireExternalCameraDrive(at: 10 + grace * 1.8)
        XCTAssertFalse(pacing.needsFrameRendering)
    }

    func testExpiryLeavesOtherActivitiesAlone() {
        let pacing = RenderLoopPacing(configuration: ImmersiveMapSettings.default.renderLoop)
        pacing.setRenderingActivity(.labelFade, isActive: true)
        pacing.noteExternalCameraDrive(at: 10)

        pacing.expireExternalCameraDrive(at: 10 + grace)

        XCTAssertTrue(pacing.needsFrameRendering)
        XCTAssertEqual(pacing.targetFramesPerSecond,
                       ImmersiveMapSettings.default.renderLoop.labelFadeFramesPerSecond)
    }
}
