// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  LowZoomOverviewFade.swift
//  ImmersiveMap
//

import simd

enum LowZoomOverviewFade {
    enum Kind {
        case overviewFeatures
        case roads
        case landuse
    }

    static let overviewStartZoom: Double = 0.0
    static let overviewEndZoom: Double = 1.0
    static let roadStartZoom: Double = 3.0
    static let roadEndZoom: Double = 4.0
    static let landuseStartZoom: Double = 13.0
    static let landuseEndZoom: Double = 14.0

    static func alpha(for zoom: Double, kind: Kind = .overviewFeatures) -> Float {
        let range: (start: Double, end: Double)
        switch kind {
        case .overviewFeatures:
            range = (overviewStartZoom, overviewEndZoom)
        case .roads:
            range = (roadStartZoom, roadEndZoom)
        case .landuse:
            range = (landuseStartZoom, landuseEndZoom)
        }

        guard range.end > range.start else {
            return zoom >= range.end ? 1.0 : 0.0
        }

        let progress = Float((zoom - range.start) / (range.end - range.start))
        let clamped = simd_clamp(progress, 0.0, 1.0)
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }
}
