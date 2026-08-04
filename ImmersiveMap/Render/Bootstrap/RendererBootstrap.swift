// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit

enum RendererSetup {
    /// The per-view half of the Metal bootstrap: stamps the shared device and
    /// color format onto this view's layer and creates the view's own command
    /// queue. Device, library and sample count come from the process-wide
    /// shared resources.
    @MainActor
    static func buildMetal(layer: CAMetalLayer,
                           sharedResources: SharedRenderResources) -> RenderMetalContext {
        layer.device = sharedResources.device
        layer.pixelFormat = sharedResources.colorPixelFormat
        guard let queue = sharedResources.device.makeCommandQueue() else {
            fatalError("Не удалось создать command queue")
        }
        return RenderMetalContext(device: sharedResources.device,
                                  commandQueue: queue,
                                  library: sharedResources.library,
                                  renderSampleCount: sharedResources.renderSampleCount)
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
