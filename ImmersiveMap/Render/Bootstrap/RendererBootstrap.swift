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
            fatalError("Could not create the command queue")
        }
        return RenderMetalContext(device: sharedResources.device,
                                  commandQueue: queue,
                                  library: sharedResources.library,
                                  renderSampleCount: sharedResources.renderSampleCount)
    }

    /// One sample everywhere: the ground's lines are antialiased
    /// analytically in the tile shaders, and the frame time the 4x world
    /// pass cost outweighed the edge smoothing it bought. The resolve
    /// machinery stays: a value above 1 turns it back on wholesale.
    static func preferredRenderSampleCount(metalDevice _: MTLDevice) -> Int {
        1
    }

    static func makeLibrary(metalDevice: MTLDevice, bundle: Bundle) -> MTLLibrary {
        do {
            return try metalDevice.makeDefaultLibrary(bundle: bundle)
        } catch {
            if let fallback = metalDevice.makeDefaultLibrary() {
                return fallback
            }
            fatalError("Could not create the MTLLibrary: \(error)")
        }
    }

    static func configureCamera(_ cameraStateController: CameraStateController) {
        //cameraStateController.setZoom(zoom: 8)
        cameraStateController.setLatLonDeg(latDeg: 55.751244, lonDeg: 37.618423)
    }
}
