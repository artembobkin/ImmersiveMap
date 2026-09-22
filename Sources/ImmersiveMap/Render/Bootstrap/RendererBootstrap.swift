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

    /// The sample counts a world pass can render with, best first.
    static let supportedRenderSampleCounts = [8, 4, 2, 1]

    /// The sample count the world pass will actually use for the one the
    /// settings ask for: the largest of the supported counts that is not
    /// above the request and that the device can render into. One sample
    /// is always available, and it is the shipped default: the ground's
    /// lines are antialiased analytically in the tile shaders, so the
    /// multisampled pass buys only geometry silhouettes.
    static func resolvedRenderSampleCount(requested: Int, metalDevice: MTLDevice) -> Int {
        supportedRenderSampleCounts.first { count in
            count <= requested && (count == 1 || metalDevice.supportsTextureSampleCount(count))
        } ?? 1
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
