// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class CameraPitchFollowTests: XCTestCase {
    private func enabledConfiguration(halfLife: Double = 0.06) -> CameraPitchFollow.Configuration {
        CameraPitchFollow.Configuration(isEnabled: true, halfLife: halfLife)
    }

    func testSteppedPitchHalvesGapAfterOneHalfLife() {
        // After one half-life the gap to the target must shrink exactly by half.
        let next = CameraPitchFollowMath.steppedPitch(current: 0,
                                                      target: 1,
                                                      deltaTime: 0.06,
                                                      halfLife: 0.06)
        XCTAssertEqual(next, 0.5, accuracy: 0.0005)
    }

    func testFollowConvergesToTargetAndDeactivates() {
        let follow = CameraPitchFollow(configuration: enabledConfiguration())
        XCTAssertTrue(follow.retarget(1.0, currentTime: 0))

        var pitch: Float = 0
        var time: CFTimeInterval = 0
        var didFinish = false
        for _ in 0..<600 { // up to 10 s at 60 fps, with headroom
            time += 1.0 / 60.0
            let step = follow.advance(currentPitch: pitch, currentTime: time)
            pitch = step.pitch
            if step.isActive == false {
                didFinish = true
                break
            }
        }

        XCTAssertTrue(didFinish, "follow must finish instead of spinning forever")
        XCTAssertFalse(follow.active)
        XCTAssertEqual(pitch, 1.0, accuracy: 0.001)
    }

    func testFollowStepIsFrameRateIndependent() {
        // The exponential model is multiplicative: the remaining gap depends only on the total
        // elapsed time, not on the number of frames. Hence 60 fps and 240 fps yield the same
        // pitch at the same point in time, which is exactly the removal of event-rate dependence.
        func pitch(afterSeconds seconds: CFTimeInterval, stepsPerSecond: Int) -> Float {
            let follow = CameraPitchFollow(configuration: enabledConfiguration())
            follow.retarget(1.0, currentTime: 0)
            var value: Float = 0
            let dt = 1.0 / CFTimeInterval(stepsPerSecond)
            let stepCount = Int((seconds / dt).rounded())
            var time: CFTimeInterval = 0
            for _ in 0..<stepCount {
                time += dt
                value = follow.advance(currentPitch: value, currentTime: time).pitch
            }
            return value
        }

        let slow = pitch(afterSeconds: 0.1, stepsPerSecond: 60)
        let fast = pitch(afterSeconds: 0.1, stepsPerSecond: 240)
        let expected = 1.0 - Float(pow(0.5, 0.1 / 0.06)) // 1 - 0.5^(T/halfLife)
        XCTAssertEqual(slow, fast, accuracy: 0.0005)
        XCTAssertEqual(slow, expected, accuracy: 0.0005)
    }

    func testFollowStopsWhenPitchSaturatedAtCeiling() {
        // If the actual pitch hits the ceiling (setCameraPitch clamps and the value stops changing)
        // while the target is higher: follow must stop, otherwise the display link spins forever.
        let follow = CameraPitchFollow(configuration: enabledConfiguration())
        follow.retarget(2.0, currentTime: 0)

        let saturatedPitch: Float = 1.0 // the ceiling; every frame we return the same value
        var time: CFTimeInterval = 0
        var becameInactive = false
        for _ in 0..<10 {
            time += 1.0 / 60.0
            let step = follow.advance(currentPitch: saturatedPitch, currentTime: time)
            if step.isActive == false {
                becameInactive = true
                break
            }
        }

        XCTAssertTrue(becameInactive, "follow must stop once it runs into the ceiling")
        XCTAssertFalse(follow.active)
    }

    func testDisabledFollowAppliesInstantly() {
        // With the setting disabled, retarget returns false and the caller applies pitch instantly.
        let follow = CameraPitchFollow(configuration: CameraPitchFollow.Configuration(isEnabled: false,
                                                                                      halfLife: 0.06))
        XCTAssertFalse(follow.retarget(1.0, currentTime: 0))
        XCTAssertFalse(follow.active)
    }

    func testRetargetWhileActiveKeepsFollowingNewTarget() {
        let follow = CameraPitchFollow(configuration: enabledConfiguration())
        follow.retarget(1.0, currentTime: 0)
        var pitch: Float = 0
        var time: CFTimeInterval = 0

        for _ in 0..<3 {
            time += 1.0 / 60.0
            pitch = follow.advance(currentPitch: pitch, currentTime: time).pitch
        }
        // Changing the target mid-flight must neither break the follow nor teleport the pitch.
        follow.retarget(0.2, currentTime: time)
        XCTAssertTrue(follow.active)

        var didFinish = false
        for _ in 0..<600 {
            time += 1.0 / 60.0
            let step = follow.advance(currentPitch: pitch, currentTime: time)
            pitch = step.pitch
            if step.isActive == false {
                didFinish = true
                break
            }
        }

        XCTAssertTrue(didFinish)
        XCTAssertEqual(pitch, 0.2, accuracy: 0.001)
    }
}
