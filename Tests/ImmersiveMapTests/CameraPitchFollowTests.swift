// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class CameraPitchFollowTests: XCTestCase {
    private func enabledConfiguration(halfLife: Double = 0.06) -> CameraPitchFollow.Configuration {
        CameraPitchFollow.Configuration(isEnabled: true, halfLife: halfLife)
    }

    func testSteppedPitchHalvesGapAfterOneHalfLife() {
        // За один half-life гэп до цели должен уменьшиться ровно вдвое.
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
        for _ in 0..<600 { // до 10 c при 60 fps — с запасом
            time += 1.0 / 60.0
            let step = follow.advance(currentPitch: pitch, currentTime: time)
            pitch = step.pitch
            if step.isActive == false {
                didFinish = true
                break
            }
        }

        XCTAssertTrue(didFinish, "follow должен завершиться, а не крутиться вечно")
        XCTAssertFalse(follow.active)
        XCTAssertEqual(pitch, 1.0, accuracy: 0.001)
    }

    func testFollowStepIsFrameRateIndependent() {
        // Экспоненциальная модель мультипликативна: остаток гэпа зависит только от суммарного
        // прошедшего времени, а не от числа кадров. Значит 60 fps и 240 fps к одному моменту
        // времени дают один и тот же pitch — это и есть устранение зависимости от частоты событий.
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
        // Если фактический pitch уперся в потолок (setCameraPitch клампит и значение не меняется),
        // а цель выше — follow обязан остановиться, иначе display link крутится бесконечно.
        let follow = CameraPitchFollow(configuration: enabledConfiguration())
        follow.retarget(2.0, currentTime: 0)

        let saturatedPitch: Float = 1.0 // потолок; каждый кадр возвращаем одно и то же значение
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

        XCTAssertTrue(becameInactive, "follow должен остановиться при упоре в потолок")
        XCTAssertFalse(follow.active)
    }

    func testDisabledFollowAppliesInstantly() {
        // При выключенной настройке retarget возвращает false — вызывающий применяет pitch мгновенно.
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
        // Смена цели на лету не должна ронять follow и не должна телепортировать pitch.
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
