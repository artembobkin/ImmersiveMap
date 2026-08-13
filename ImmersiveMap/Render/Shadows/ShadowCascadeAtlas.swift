// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import os

/// Layout of the shadow texture array: cascade `i` rasterizes into slice `i`,
/// routed there by `[[render_target_array_index]]` in the caster vertex
/// stages. Shared by the caster drawers, the attachment store and the
/// resolver's UV math so the slices can never disagree with the sampling
/// matrices.
enum ShadowCascadeAtlas {
    /// Near (crisp) / middle / far. Texel world size roughly triples per
    /// step; the middle cascade exists because at a tilted camera most
    /// visible shadows land beyond the near disc, where far-cascade texels
    /// (~11 m) visibly wobble diagonal shadow edges.
    static let cascadeCount = 3

    /// 16 bits are enough: every cascade projection is refit each frame to a
    /// tight caster range with depth clamping, and the receiver bias is
    /// derived from the texel footprint rather than raw depth deltas, so the
    /// extra depth32Float precision bought nothing while doubling atlas
    /// memory and the bandwidth of every `sample_compare` tap. Shared by the
    /// atlas texture, the caster pipelines and the fallback texture so their
    /// formats can never disagree.
    static let depthPixelFormat: MTLPixelFormat = .depth16Unorm

    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Shadows")
    private static let didWarnAboutLayeredRendering = OSAllocatedUnfairLock(initialState: false)

    /// Whether the cascades can be rasterized the way this atlas is built:
    /// one pass writing three slices, with the caster vertex stages routing
    /// instances through `[[render_target_array_index]]`.
    ///
    /// Every GPU the package targets supports it (Apple5 and later covers all
    /// iOS 18 hardware, mac2 covers every Mac), but the iOS Simulator does
    /// not: a pass descriptor with `renderTargetArrayLength > 0` fails Metal
    /// validation there, which aborts the process rather than returning an
    /// error. Shadows are therefore left out on such a device instead of
    /// taking the app down with them, and the frame is drawn without them.
    static func supportsLayeredRendering(device: MTLDevice) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return device.supportsFamily(.apple5) || device.supportsFamily(.mac2)
        #endif
    }

    /// Says once per process why the frame has no shadows, so the difference
    /// from a device build is visible in the console rather than left to be
    /// mistaken for a rendering bug.
    static func warnAboutMissingLayeredRenderingOnce() {
        let shouldWarn = didWarnAboutLayeredRendering.withLock { didWarn -> Bool in
            guard didWarn == false else {
                return false
            }
            didWarn = true
            return true
        }
        guard shouldWarn else {
            return
        }
        logger.warning("""
            Shadows are disabled: this device does not support layered rendering, \
            which the cascade shadow maps rasterize through. The iOS Simulator is \
            the usual case; run on a device to see shadows.
            """)
    }
}
