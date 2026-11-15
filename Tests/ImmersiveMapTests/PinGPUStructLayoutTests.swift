// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The Swift instance structs are mirrored by hand in PinCommon.h - strides
/// and field offsets are pinned so a desync is caught without compiling Metal.
final class PinGPUStructLayoutTests: XCTestCase {
    func testPinInstanceLayoutMatchesMetalMirror() throws {
        XCTAssertEqual(MemoryLayout<PinInstanceGPU>.stride, 64)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinInstanceGPU>.offset(of: \.uvRect)), 0)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinInstanceGPU>.offset(of: \.borderColor)), 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinInstanceGPU>.offset(of: \.squashScale)), 32)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinInstanceGPU>.offset(of: \.atlasIndex)), 40)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinInstanceGPU>.offset(of: \.flags)), 44)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinInstanceGPU>.offset(of: \.morph)), 48)
    }

    func testBadgeInstanceLayoutsMatchMetalMirror() throws {
        XCTAssertEqual(MemoryLayout<PinCountBadgeInstanceGPU>.stride, 32)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinCountBadgeInstanceGPU>.offset(of: \.flags)), 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinCountBadgeInstanceGPU>.offset(of: \.screenSizeScale)), 20)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinCountBadgeInstanceGPU>.offset(of: \.contentAlpha)), 24)
    }

    func testBeamStructLayoutsMatchMetalMirror() throws {
        XCTAssertEqual(MemoryLayout<PinOffset>.stride, 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinOffset>.offset(of: \.value)), 0)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinOffset>.offset(of: \.scale)), 8)

        XCTAssertEqual(MemoryLayout<PinBeamStyleGPU>.stride, 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinBeamStyleGPU>.offset(of: \.pinCenterOffsetPx)), 0)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinBeamStyleGPU>.offset(of: \.pinBodyHalfMinPx)), 4)
    }

    func testScreenPointOutputLayoutIsUnchanged() {
        XCTAssertEqual(MemoryLayout<ScreenPointOutput>.stride, 24)
    }
}
