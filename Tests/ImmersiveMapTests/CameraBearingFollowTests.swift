// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class CameraBearingFollowTests: XCTestCase {
    private func enabledConfiguration(halfLife: Double = 0.06) -> CameraBearingFollow.Configuration {
        CameraBearingFollow.Configuration(isEnabled: true, halfLife: halfLife)
    }

    private func radians(_ degrees: Float) -> Float {
        degrees * .pi / 180
    }

    func testShortestDeltaTakesShortPathAcrossWrap() {
        // 170° -> -170° это +20° через 180°, а не -340° вокруг.
        let delta = CameraBearingFollowMath.shortestDelta(current: radians(170), target: radians(-170))
        XCTAssertEqual(delta, radians(20), accuracy: 0.001)
    }

    func testFollowConvergesToTargetAndDeactivates() {
        let follow = CameraBearingFollow(configuration: enabledConfiguration())
        XCTAssertTrue(follow.retarget(radians(90), currentTime: 0))

        var bearing = radians(0)
        var time: CFTimeInterval = 0
        var didFinish = false
        for _ in 0..<600 {
            time += 1.0 / 60.0
            let step = follow.advance(currentBearing: bearing, currentTime: time)
            bearing = step.bearing
            if step.isActive == false {
                didFinish = true
                break
            }
        }

        XCTAssertTrue(didFinish, "follow должен завершиться, а не крутиться вечно")
        XCTAssertFalse(follow.active)
        XCTAssertEqual(bearing, radians(90), accuracy: 0.001)
    }

    func testFollowCrossesWrapBoundaryTheShortWay() {
        // От 170° к -170° follow должен идти ВВЕРХ через 180° (bearing растет), а не вниз через 0.
        let follow = CameraBearingFollow(configuration: enabledConfiguration())
        let start = radians(170)
        let target = radians(-170)
        follow.retarget(target, currentTime: 0)

        var bearing = start
        var maximumBearing = start
        var time: CFTimeInterval = 0
        var didFinish = false
        for _ in 0..<600 {
            time += 1.0 / 60.0
            let step = follow.advance(currentBearing: bearing, currentTime: time)
            bearing = step.bearing
            maximumBearing = max(maximumBearing, bearing)
            if step.isActive == false {
                didFinish = true
                break
            }
        }

        XCTAssertTrue(didFinish)
        XCTAssertGreaterThan(maximumBearing, start, "должен был пройти вверх через 180°")
        XCTAssertEqual(CameraBearingFollowMath.shortestDelta(current: bearing, target: target),
                       0,
                       accuracy: 0.001)
    }

    func testFollowStepIsFrameRateIndependent() {
        func bearing(afterSeconds seconds: CFTimeInterval, stepsPerSecond: Int) -> Float {
            let follow = CameraBearingFollow(configuration: enabledConfiguration())
            follow.retarget(radians(90), currentTime: 0)
            var value = radians(0)
            let dt = 1.0 / CFTimeInterval(stepsPerSecond)
            let stepCount = Int((seconds / dt).rounded())
            var time: CFTimeInterval = 0
            for _ in 0..<stepCount {
                time += dt
                value = follow.advance(currentBearing: value, currentTime: time).bearing
            }
            return value
        }

        let slow = bearing(afterSeconds: 0.1, stepsPerSecond: 60)
        let fast = bearing(afterSeconds: 0.1, stepsPerSecond: 240)
        XCTAssertEqual(slow, fast, accuracy: 0.001)
    }

    func testFollowStopsWhenBearingSaturatedAtLimit() {
        // Если bearing уперся в constraint (значение не меняется), а цель выше — follow обязан
        // остановиться, иначе display link крутится бесконечно.
        let follow = CameraBearingFollow(configuration: enabledConfiguration())
        follow.retarget(radians(90), currentTime: 0)

        let saturatedBearing = radians(30) // предел; каждый кадр возвращаем одно и то же
        var time: CFTimeInterval = 0
        var becameInactive = false
        for _ in 0..<10 {
            time += 1.0 / 60.0
            let step = follow.advance(currentBearing: saturatedBearing, currentTime: time)
            if step.isActive == false {
                becameInactive = true
                break
            }
        }

        XCTAssertTrue(becameInactive, "follow должен остановиться при упоре в предел")
        XCTAssertFalse(follow.active)
    }

    func testDisabledFollowAppliesInstantly() {
        let follow = CameraBearingFollow(configuration: CameraBearingFollow.Configuration(isEnabled: false,
                                                                                          halfLife: 0.06))
        XCTAssertFalse(follow.retarget(radians(90), currentTime: 0))
        XCTAssertFalse(follow.active)
    }
}
