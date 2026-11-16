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
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinBeamStyleGPU>.offset(of: \.pinBodyHalfMinPx)), 8)
    }

    func testPinStyleLayoutMatchesMetalMirror() throws {
        XCTAssertEqual(MemoryLayout<PinStyleGPU>.stride, 80)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.sizePx)), 0)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.anchorUv)), 8)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.bodyCenterUv)), 16)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.bodyHalfUv)), 24)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.circleRadiusUv)), 32)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.outlineWidthPx)), 36)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.contentInsetPx)), 40)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.distanceRangeTexels)), 44)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.fillColor)), 48)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.frameless)), 64)
        XCTAssertEqual(try XCTUnwrap(MemoryLayout<PinStyleGPU>.offset(of: \.distanceInAlpha)), 68)
    }

    func testScreenPointOutputLayoutIsUnchanged() {
        XCTAssertEqual(MemoryLayout<ScreenPointOutput>.stride, 24)
    }
}
