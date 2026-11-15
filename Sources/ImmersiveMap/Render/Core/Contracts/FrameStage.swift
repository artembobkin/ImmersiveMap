// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  FrameStage.swift
//  ImmersiveMap
//

import Foundation

enum FrameStage: String, CaseIterable {
    case collectInput
    case updateScene
    case prepareGPU
    case encodePasses
    case presentFrame
}
