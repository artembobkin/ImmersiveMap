// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit
import OSLog

/// Why the renderer could not be built. The map view shows the description
/// in place of the map, and the offscreen recorders throw it inside their
/// own errors.
enum RenderResourcesError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The resource bundle holds no shader library, and the app's main
    /// library does not hold the engine's shaders either.
    case shaderLibraryUnavailable(bundlePath: String, reason: String)

    var description: String {
        switch self {
        case let .shaderLibraryUnavailable(bundlePath, reason):
            return "The map's shader library could not be loaded from \(bundlePath) (\(reason)), and the app's own library does not hold the map's shaders."
        }
    }

    var errorDescription: String? { description }
}

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

    /// The engine's shaders: the `default.metallib` of its resource bundle
    /// (`ImmersiveMapResourceBundle`), which the build tool plugin
    /// `MetalLibraryPlugin` compiles whoever builds the package. When the
    /// bundle has none, the main bundle's default library is taken if it
    /// holds the engine's shaders, which is how an app that compiled them
    /// into its own library still runs. Otherwise the map cannot draw, and
    /// the error says so: the map view shows it, an export throws it.
    static func makeLibrary(metalDevice: MTLDevice, bundle: Bundle) throws -> MTLLibrary {
        let bundleFailure: any Error
        do {
            return try metalDevice.makeDefaultLibrary(bundle: bundle)
        } catch {
            bundleFailure = error
        }
        if let fallback = metalDevice.makeDefaultLibrary(),
           fallback.functionNames.contains(engineFunctionName) {
            logger.warning("ImmersiveMap: the resource bundle at \(bundle.bundlePath, privacy: .public) holds no shader library (\(String(describing: bundleFailure), privacy: .public)), so the app's main library is used.")
            return fallback
        }
        throw RenderResourcesError.shaderLibraryUnavailable(bundlePath: bundle.bundlePath,
                                                            reason: String(describing: bundleFailure))
    }

    /// An entry point every build of the engine's shaders holds: what tells
    /// the engine's shaders apart from an app's own in the main library.
    static let engineFunctionName = "fxaaFragmentShader"

    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Renderer")

    static func configureCamera(_ cameraStateController: CameraStateController) {
        //cameraStateController.setZoom(zoom: 8)
        cameraStateController.setLatLonDeg(latDeg: 55.751244, lonDeg: 37.618423)
    }
}
