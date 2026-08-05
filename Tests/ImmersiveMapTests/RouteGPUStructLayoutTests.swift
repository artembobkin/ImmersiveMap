// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import simd
import XCTest

/// Pins the byte layout of the Swift mirror of `RouteUniform` in Route.metal
/// and the centerline point element: a drifted offset would silently corrupt
/// every route draw, and the shader cannot be type-checked against Swift.
final class RouteGPUStructLayoutTests: XCTestCase {
    func testRouteUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<RouteUniformGPU>.size, 48)
        XCTAssertEqual(MemoryLayout<RouteUniformGPU>.stride, 48)
        XCTAssertEqual(MemoryLayout<RouteUniformGPU>.offset(of: \.viewport), 0)
        XCTAssertEqual(MemoryLayout<RouteUniformGPU>.offset(of: \.halfWidthPx), 8)
        XCTAssertEqual(MemoryLayout<RouteUniformGPU>.offset(of: \.sampleCount), 12)
        XCTAssertEqual(MemoryLayout<RouteUniformGPU>.offset(of: \.color), 16)
        XCTAssertEqual(MemoryLayout<RouteUniformGPU>.offset(of: \.dashPx), 32)
        XCTAssertEqual(MemoryLayout<RouteUniformGPU>.offset(of: \.gapPx), 36)
    }

    func testCenterlinePointIsAFloat4() {
        XCTAssertEqual(MemoryLayout<RouteWorldGeometryBuilder.Point>.size, 16)
        XCTAssertEqual(MemoryLayout<RouteWorldGeometryBuilder.Point>.stride, 16)
    }

    /// Per-route buffer offsets are padded to whole 256-byte blocks, which is
    /// the strictest `setVertexBuffer` alignment across the supported platforms.
    func testBufferAlignmentsCoverTheStrictestOffsetRule() {
        XCTAssertEqual(MemoryLayout<RouteWorldGeometryBuilder.Point>.stride * 16, 256)
        XCTAssertEqual(MemoryLayout<Float>.stride * 64, 256)
    }
}

/// The only automated protection against a typo in a shader function name:
/// the pipeline links its Metal functions. Skips itself where `swift test`
/// cannot compile shaders.
final class RoutePipelineIntegrationTests: XCTestCase {
    func testRoutePipelineLinksItsShaderFunctions() throws {
        let device = try makeDeviceOrSkip()
        let library = try XCTUnwrap(try? device.makeDefaultLibrary(bundle: .module))

        XCTAssertNotNil(library.makeFunction(name: "routeVertexShader"))
        XCTAssertNotNil(library.makeFunction(name: "routeFragmentShader"))

        let pipeline = RoutePipeline(metalDevice: device,
                                     pixelFormat: .bgra8Unorm,
                                     library: library,
                                     sampleCount: 1)
        XCTAssertNotNil(pipeline.pipelineState)
    }

    private func makeDeviceOrSkip() throws -> MTLDevice {
        guard let probeDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? probeDevice.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
        return probeDevice
    }
}
