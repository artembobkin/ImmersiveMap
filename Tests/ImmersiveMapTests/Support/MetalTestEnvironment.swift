// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// Whether this process can run a GPU test, and whether it is allowed to duck
/// out of one.
///
/// Every Metal-backed test skips itself when the environment cannot serve it,
/// which is right for `swift test` (SwiftPM does not compile the `.metal`
/// sources for the test bundle) and wrong for the CI job that exists to run
/// exactly those tests: there, a suite that skips its way to green reports
/// health it never checked. That job sets `IMMERSIVE_MAP_REQUIRE_METAL=1`, and
/// this type turns the skips into failures.
enum MetalTestEnvironment {
    /// Set to `1` by the CI job whose whole purpose is the GPU suite.
    static let requirementKey = "IMMERSIVE_MAP_REQUIRE_METAL"

    static var isMetalRequired: Bool {
        ProcessInfo.processInfo.environment[requirementKey] == "1"
    }

    /// Why a headless frame cannot run here, or nil when it can.
    ///
    /// `hasUnifiedMemory` is part of the answer because these tests read the
    /// rendered texture back with `getBytes`, which needs shared storage.
    static func unavailabilityReason() -> String? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return "Metal device is unavailable"
        }
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            return "Compiled Metal library is unavailable in this test environment"
        }
        guard device.hasUnifiedMemory else {
            return "Unified-memory GPU is required for direct texture readback"
        }
        return nil
    }

    /// The Metal device for a GPU test, or the appropriate way out: `XCTSkip`
    /// normally, a thrown failure when the run declared it requires Metal.
    @discardableResult
    static func requireDevice() throws -> MTLDevice {
        if let reason = unavailabilityReason() {
            if isMetalRequired {
                throw MissingMetalError(reason: reason)
            }
            throw XCTSkip(reason)
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MissingMetalError(reason: "Metal device disappeared between checks")
        }
        return device
    }

    struct MissingMetalError: Error, CustomStringConvertible {
        let reason: String

        var description: String {
            """
            \(reason). This run set \(MetalTestEnvironment.requirementKey)=1, so the GPU tests \
            must actually execute: a skipped GPU suite reports health it never checked.
            """
        }
    }
}

/// Guards the guard: one test whose only job is to notice that the run which
/// promised to exercise the GPU cannot. Without it, losing Metal on the CI
/// runner would turn every Metal-backed test into a skip and the job would stay
/// green while covering nothing.
final class MetalTestEnvironmentTests: XCTestCase {
    func testGPURunCanActuallyRenderWhenItSaysItMust() throws {
        guard MetalTestEnvironment.isMetalRequired else {
            throw XCTSkip("""
            This run does not require Metal (\(MetalTestEnvironment.requirementKey) is unset), \
            so the GPU tests are free to skip themselves.
            """)
        }
        XCTAssertNil(MetalTestEnvironment.unavailabilityReason(),
                     "The GPU suite was required to run, but this environment cannot render a headless frame")
    }
}
