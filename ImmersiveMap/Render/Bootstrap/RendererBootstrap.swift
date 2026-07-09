// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit

enum RendererSetup {
    static func buildMetal(layer: CAMetalLayer) -> RenderMetalContext {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal не поддерживается на этом устройстве")
        }
        layer.device = metalDevice
        layer.pixelFormat = .bgra8Unorm
        guard let queue = metalDevice.makeCommandQueue() else {
            fatalError("Не удалось создать command queue")
        }
        let bundle = Bundle.module
        let library = makeLibrary(metalDevice: metalDevice, bundle: bundle)
        return RenderMetalContext(device: metalDevice,
                                  commandQueue: queue,
                                  library: library,
                                  renderSampleCount: preferredRenderSampleCount(metalDevice: metalDevice))
    }

    static func preferredRenderSampleCount(metalDevice: MTLDevice) -> Int {
        metalDevice.supportsTextureSampleCount(4) ? 4 : 1
    }

    static func makeLibrary(metalDevice: MTLDevice, bundle: Bundle) -> MTLLibrary {
        do {
            return try metalDevice.makeDefaultLibrary(bundle: bundle)
        } catch {
            if let fallback = metalDevice.makeDefaultLibrary() {
                return fallback
            }
            fatalError("Не удалось создать MTLLibrary: \(error)")
        }
    }

    static func makeMapSurfaceGridBuffers(metalDevice: MTLDevice) -> MapSurfaceGridBuffers {
        let baseGrid = SphereGeometry.createGrid(stacks: 60, slices: 60)
        return MapSurfaceGridBuffers(
            verticesBuffer: metalDevice.makeBuffer(
                bytes: baseGrid.vertices,
                length: MemoryLayout<SphereGeometry.Vertex>.stride * baseGrid.vertices.count
            )!,
            indicesBuffer: metalDevice.makeBuffer(
                bytes: baseGrid.indices,
                length: MemoryLayout<UInt32>.stride * baseGrid.indices.count
            )!,
            indicesCount: baseGrid.indices.count
        )
    }

    static func configureCamera(_ cameraStateController: CameraStateController) {
        //cameraStateController.setZoom(zoom: 8)
        cameraStateController.setLatLonDeg(latDeg: 55.751244, lonDeg: 37.618423)
    }
}
