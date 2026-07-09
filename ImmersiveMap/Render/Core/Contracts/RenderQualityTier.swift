// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderQualityTier.swift
//  ImmersiveMap
//

import Foundation

enum RenderQualityTier {
    case low
    case standard
    case high

    static func from(zoom: Double) -> RenderQualityTier {
        if zoom < 7.0 {
            return .low
        }
        if zoom < 13.0 {
            return .standard
        }
        return .high
    }
}
