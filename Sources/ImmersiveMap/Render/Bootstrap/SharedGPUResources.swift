// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// What a set of shared GPU resources is built from: the device, the
/// engine's shader library, the bundle its files are read from, and the
/// format and the sample count of the world pass. A set that draws in a
/// pass of one sample (the overlay, the text) leaves `sampleCount` unread.
struct SharedGPUResourceBuild {
    let device: MTLDevice
    let library: MTLLibrary
    let resourceBundle: Bundle
    let pixelFormat: MTLPixelFormat
    let sampleCount: Int
}

/// The immutable GPU resources of one feature that every renderer of the
/// process shares: its pipelines, its depth and stencil states, its static
/// geometry, its atlases. A feature declares its set in its own folder, and
/// `Render` learns of it by one entry in
/// `RenderGraphFactory.sharedResourceTypes`: `SharedRenderResources` builds
/// the listed sets, one per sample count, and names none of them.
///
/// The sets are built side by side, away from the main thread, so `make`
/// touches nothing but its argument, and one set is one unit of that
/// work: a feature with several heavy pipelines declares several sets
/// rather than one that compiles them in a row. A set never mutates after
/// `make` returns, and is read from any thread.
protocol SharedGPUResources {
    static func make(_ build: SharedGPUResourceBuild) -> Self
}

/// A shared set that has to be made on the main thread (one that
/// rasterizes through UIImage or NSImage). It is made after the others,
/// when the background build has returned.
protocol MainThreadSharedGPUResources {
    @MainActor static func make(device: MTLDevice) -> Self
}
