// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import SwiftUI

public extension Scene {
    /// Opens the scene's windows at `format`'s size, `.threadsVideo` for a
    /// 1080 × 1920 window on a Retina screen, so a screenshot or a screen
    /// recording of the window is ready to post:
    ///
    /// ```swift
    /// WindowGroup {
    ///     ContentView()
    /// }
    /// .windowFormat(.threadsVideo)
    /// ```
    ///
    /// The size is the window's content, in the main screen's pixels. When
    /// the screen cannot hold that many, the window is smaller with the
    /// same proportion. Every launch opens at the format: macOS does not
    /// restore the size a window had when the app quit, since a restored
    /// size would win over the format (`restorationBehavior(.disabled)`).
    /// The window can still be resized by hand afterwards.
    ///
    /// macOS only.
    func windowFormat(_ format: ImmersiveMapFrameFormat) -> some Scene {
        defaultSize(WindowFormatSizing.contentSize(for: format))
            .restorationBehavior(.disabled)
    }
}

/// The window's size for a frame format.
@MainActor
enum WindowFormatSizing {
    /// The content size, in points, that is `format`'s pixels on the main
    /// screen, scaled down with the same proportion to fit the screen's
    /// visible frame below a title bar.
    static func contentSize(for format: ImmersiveMapFrameFormat) -> CGSize {
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let size = CGSize(width: CGFloat(format.pixelWidth) / scale,
                          height: CGFloat(format.pixelHeight) / scale)
        guard let available = screen?.visibleFrame.size else { return size }
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let frame = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: size), styleMask: styleMask)
        let titleBar = frame.height - size.height
        let fit = min(1, available.width / size.width, (available.height - titleBar) / size.height)
        return CGSize(width: (size.width * fit).rounded(.down),
                      height: (size.height * fit).rounded(.down))
    }
}

#endif
