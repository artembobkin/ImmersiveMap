// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Configuration of an offline tour video export: output dimensions, frame
/// rate, codec, and readiness policy.
///
/// The output container is always QuickTime (`.mov`); it carries both
/// supported codecs natively.
public struct ImmersiveMapVideoExportConfiguration: Sendable, Equatable {
    public enum Codec: Sendable, Equatable {
        /// HEVC (H.265) — what Apple devices record by default. Smaller files
        /// at equal quality; slightly less universal outside the Apple
        /// ecosystem.
        case hevc
        /// H.264 — maximum compatibility, larger files.
        case h264
    }

    /// Output width in pixels. Must be even, within 64...8192.
    public var width: Int
    /// Output height in pixels. Must be even, within 64...8192.
    public var height: Int
    /// Output frame rate. Must be within 1...120.
    public var framesPerSecond: Int
    public var codec: Codec
    /// Target average bit rate in bits per second. `nil` picks a default from
    /// the frame geometry: 0.10 bits/pixel for HEVC, 0.20 for H.264
    /// (~12 / ~25 Mbit/s at 1080p60).
    public var averageBitRate: Int?
    /// How long a single frame may wait for outstanding tiles before it is
    /// captured with whatever has loaded. Also caps the pre-roll that settles
    /// the scene before the first frame.
    public var tileReadinessTimeout: TimeInterval
    /// Wall date used for the earth scene (sun position) across the whole
    /// export. `nil` fixes it to the moment the export starts.
    public var sceneDate: Date?
    /// Whether avatar markers are rendered into the exported video. The export
    /// uses a detached copy of the avatar state taken at export start, so live
    /// avatar updates during the export are not captured.
    public var includesAvatars: Bool
    /// Whether SwiftUI markers (`.markers(...)`) are composited into the
    /// exported video. Marker views are rasterized once at export start and
    /// follow the same per-frame projection (including the globe-horizon fade)
    /// as on screen.
    public var includesMarkers: Bool
    /// Rasterization scale of SwiftUI markers, in pixels per point. The
    /// default `2` sizes markers as on a Retina display whose drawable matches
    /// the export resolution. Allowed range 0.5...8.
    public var markerScale: Double

    public static let `default` = ImmersiveMapVideoExportConfiguration()

    public init(width: Int = 1920,
                height: Int = 1080,
                framesPerSecond: Int = 60,
                codec: Codec = .hevc,
                averageBitRate: Int? = nil,
                tileReadinessTimeout: TimeInterval = 10,
                sceneDate: Date? = nil,
                includesAvatars: Bool = true,
                includesMarkers: Bool = true,
                markerScale: Double = 2.0) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.codec = codec
        self.averageBitRate = averageBitRate
        self.tileReadinessTimeout = tileReadinessTimeout
        self.sceneDate = sceneDate
        self.includesAvatars = includesAvatars
        self.includesMarkers = includesMarkers
        self.markerScale = markerScale
    }

    var resolvedAverageBitRate: Int {
        if let averageBitRate {
            return averageBitRate
        }
        let bitsPerPixel: Double = codec == .hevc ? 0.10 : 0.20
        return Int(Double(width) * Double(height) * Double(framesPerSecond) * bitsPerPixel)
    }

    func validate() throws {
        let sizeRange = 64...8192
        guard sizeRange.contains(width), sizeRange.contains(height) else {
            throw ImmersiveMapVideoExportError.invalidConfiguration(
                "width and height must be within \(sizeRange), got \(width)×\(height)")
        }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw ImmersiveMapVideoExportError.invalidConfiguration(
                "width and height must be even, got \(width)×\(height)")
        }
        guard (1...120).contains(framesPerSecond) else {
            throw ImmersiveMapVideoExportError.invalidConfiguration(
                "framesPerSecond must be within 1...120, got \(framesPerSecond)")
        }
        if let averageBitRate, averageBitRate <= 0 {
            throw ImmersiveMapVideoExportError.invalidConfiguration(
                "averageBitRate must be positive, got \(averageBitRate)")
        }
        guard tileReadinessTimeout > 0 else {
            throw ImmersiveMapVideoExportError.invalidConfiguration(
                "tileReadinessTimeout must be positive, got \(tileReadinessTimeout)")
        }
        guard (0.5...8).contains(markerScale) else {
            throw ImmersiveMapVideoExportError.invalidConfiguration(
                "markerScale must be within 0.5...8, got \(markerScale)")
        }
    }
}
