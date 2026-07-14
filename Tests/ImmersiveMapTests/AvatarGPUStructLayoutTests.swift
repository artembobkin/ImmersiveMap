// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Swift-структуры инстансов зеркалируются вручную в AvatarCommon.h - страйды
/// и смещения полей закреплены, чтобы рассинхрон ловился без компиляции Metal.
final class AvatarGPUStructLayoutTests: XCTestCase {
    func testAvatarInstanceLayoutMatchesMetalMirror() throws {
        XCTAssertEqual(MemoryLayout<AvatarInstanceGPU>.stride, 64)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarInstanceGPU>.offset(of: \.uvRect)), 0)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarInstanceGPU>.offset(of: \.borderColor)), 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarInstanceGPU>.offset(of: \.squashScale)), 32)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarInstanceGPU>.offset(of: \.atlasIndex)), 40)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarInstanceGPU>.offset(of: \.flags)), 44)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarInstanceGPU>.offset(of: \.morph)), 48)
    }

    func testBadgeInstanceLayoutsMatchMetalMirror() throws {
        XCTAssertEqual(MemoryLayout<AvatarBatteryBadgeInstanceGPU>.stride, 32)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarBatteryBadgeInstanceGPU>.offset(of: \.flags)), 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarBatteryBadgeInstanceGPU>.offset(of: \.screenSizeScale)), 20)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarBatteryBadgeInstanceGPU>.offset(of: \.contentAlpha)), 24)

        XCTAssertEqual(MemoryLayout<AvatarSpeedBadgeInstanceGPU>.stride, 32)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarSpeedBadgeInstanceGPU>.offset(of: \.flags)), 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarSpeedBadgeInstanceGPU>.offset(of: \.screenSizeScale)), 20)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarSpeedBadgeInstanceGPU>.offset(of: \.contentAlpha)), 24)
    }

    func testBeamStructLayoutsMatchMetalMirror() throws {
        XCTAssertEqual(MemoryLayout<AvatarOffset>.stride, 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarOffset>.offset(of: \.value)), 0)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarOffset>.offset(of: \.scale)), 8)

        XCTAssertEqual(MemoryLayout<AvatarBeamStyleGPU>.stride, 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarBeamStyleGPU>.offset(of: \.markerCenterOffsetPx)), 0)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<AvatarBeamStyleGPU>.offset(of: \.markerBodyHalfMinPx)), 4)
    }

    func testScreenPointOutputLayoutIsUnchanged() {
        XCTAssertEqual(MemoryLayout<ScreenPointOutput>.stride, 24)
    }
}
