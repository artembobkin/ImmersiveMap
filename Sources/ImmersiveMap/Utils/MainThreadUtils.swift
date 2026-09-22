// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The `Utils` folder: small cross-cutting helpers with several callers and no
/// better domain owner, such as deterministic math, main-thread checks,
/// signposts and the platform graphics shims UIKit and AppKit code share. It
/// stays narrow: a helper with one caller belongs next to that caller, and no
/// subsystem, runtime controller, renderer, parser, cache or public API of a
/// domain folder lives here.
func performOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
        block()
    } else {
        DispatchQueue.main.async(execute: block)
    }
}
