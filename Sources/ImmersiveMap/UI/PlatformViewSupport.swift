// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
import UIKit

/// The map's platform host view: UIKit on iOS, AppKit on macOS.
/// Shared runtime files reference this typealias, not the concrete class.
typealias ImmersiveMapHostView = ImmersiveMapUIView
typealias PlatformEdgeInsets = UIEdgeInsets
#elseif canImport(AppKit)
import AppKit

typealias ImmersiveMapHostView = ImmersiveMapNSView
typealias PlatformEdgeInsets = NSEdgeInsets

extension NSEdgeInsets {
    static var zero: NSEdgeInsets {
        NSEdgeInsetsZero
    }
}
#endif
