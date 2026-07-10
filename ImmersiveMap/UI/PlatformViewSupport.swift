// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
import UIKit

/// Платформенный host view карты: UIKit на iOS, AppKit на macOS.
/// Общие runtime-файлы ссылаются на этот typealias, а не на конкретный класс.
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
