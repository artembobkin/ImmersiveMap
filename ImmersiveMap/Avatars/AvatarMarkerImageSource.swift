// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

public struct AvatarMarkerImageSource: Sendable {
    private enum Storage {
        case cgImage(CGImage)
        case remote(URL, placeholder: CGImage?)
    }

    private let storage: Storage

    public var remoteURL: URL? {
        switch storage {
        case .cgImage:
            return nil
        case .remote(let url, placeholder: _):
            return url
        }
    }

    var initialImage: CGImage {
        switch storage {
        case .cgImage(let image):
            return image
        case .remote(_, let placeholder):
            return placeholder ?? AvatarMarkerImageLoader.defaultPlaceholderCGImage
        }
    }

    public static func cgImage(_ image: CGImage) -> AvatarMarkerImageSource {
        AvatarMarkerImageSource(storage: .cgImage(image))
    }

    public static func remote(_ url: URL, placeholder: CGImage? = nil) -> AvatarMarkerImageSource {
        AvatarMarkerImageSource(storage: .remote(url, placeholder: placeholder))
    }
}
