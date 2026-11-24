// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// A size of the map's frame in pixels: the size a platform asks for an
/// image or a video, so a frame of the map is ready to post there. A
/// picture takes it with `ImmersiveMapStillConfiguration(format:)`, a video
/// with `ImmersiveMapVideoExportConfiguration(format:)`, and a window on
/// macOS with the scene's `windowFormat(_:)`.
///
/// The presets are each platform's recommended upload size. Any other size
/// is `ImmersiveMapFrameFormat(pixelWidth:pixelHeight:)`.
public struct ImmersiveMapFrameFormat: Hashable, Sendable {
    /// The frame's width in pixels.
    public let pixelWidth: Int
    /// The frame's height in pixels.
    public let pixelHeight: Int

    /// A frame of `pixelWidth` by `pixelHeight` pixels. A side below one
    /// pixel is taken as one.
    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
    }

    /// The width over the height: 0.8 for a 4:5 portrait, 1.78 for 16:9.
    public var aspectRatio: Double {
        Double(pixelWidth) / Double(pixelHeight)
    }

    // MARK: Threads

    /// A Threads post: 4:5, 1080 × 1350.
    public static let threadsPost = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1350)
    /// A square Threads post: 1:1, 1080 × 1080.
    public static let threadsSquare = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1080)
    /// A Threads video: 9:16, 1080 × 1920.
    public static let threadsVideo = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1920)

    // MARK: X (Twitter)

    /// An X image in landscape: 16:9, 1600 × 900.
    public static let xLandscape = ImmersiveMapFrameFormat(pixelWidth: 1600, pixelHeight: 900)
    /// A square X image: 1:1, 1080 × 1080.
    public static let xSquare = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1080)
    /// An X video: 16:9, 1920 × 1080.
    public static let xVideo = ImmersiveMapFrameFormat(pixelWidth: 1920, pixelHeight: 1080)

    // MARK: Instagram

    /// An Instagram feed post: 4:5, 1080 × 1350.
    public static let instagramFeed = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1350)
    /// An Instagram post as the profile grid shows it: 3:4, 1080 × 1440.
    public static let instagramGrid = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1440)
    /// Instagram Reels and Stories: 9:16, 1080 × 1920.
    public static let instagramReels = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1920)

    // MARK: TikTok

    /// A TikTok video: 9:16, 1080 × 1920.
    public static let tikTokVideo = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1920)

    // MARK: YouTube

    /// A YouTube video: 16:9, 1920 × 1080.
    public static let youTubeVideo = ImmersiveMapFrameFormat(pixelWidth: 1920, pixelHeight: 1080)
    /// A YouTube Short: 9:16, 1080 × 1920.
    public static let youTubeShorts = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1920)

    // MARK: LinkedIn

    /// A LinkedIn post in portrait: 4:5, 1080 × 1350.
    public static let linkedInPortrait = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1350)
    /// A LinkedIn link preview: 1.91:1, 1200 × 627.
    public static let linkedInLink = ImmersiveMapFrameFormat(pixelWidth: 1200, pixelHeight: 627)

    // MARK: Facebook

    /// A Facebook feed post: 4:5, 1080 × 1350.
    public static let facebookFeed = ImmersiveMapFrameFormat(pixelWidth: 1080, pixelHeight: 1350)
    /// A Facebook link preview: 1.91:1, 1200 × 630.
    public static let facebookLink = ImmersiveMapFrameFormat(pixelWidth: 1200, pixelHeight: 630)

    // MARK: GitHub

    /// A GitHub repository's social preview: 2:1, 1280 × 640.
    public static let gitHubSocialPreview = ImmersiveMapFrameFormat(pixelWidth: 1280, pixelHeight: 640)

    // MARK: Screens

    /// Full HD: 16:9, 1920 × 1080.
    public static let fullHD = ImmersiveMapFrameFormat(pixelWidth: 1920, pixelHeight: 1080)
    /// 4K UHD: 16:9, 3840 × 2160.
    public static let uhd4K = ImmersiveMapFrameFormat(pixelWidth: 3840, pixelHeight: 2160)
}
