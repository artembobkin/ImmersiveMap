// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

enum RenderFrameColorDestination: Equatable {
    case drawable
    case postProcessingInput
}

struct RenderFrameOutputPlan: Equatable {
    let worldColorDestination: RenderFrameColorDestination
    let usesMultisampleResolve: Bool

    var includesPostProcessingPass: Bool {
        worldColorDestination == .postProcessingInput
    }
}

enum RenderFrameOutputPlanner {
    static func plan(fxaaEnabled: Bool,
                     renderSampleCount: Int) -> RenderFrameOutputPlan {
        RenderFrameOutputPlan(
            worldColorDestination: fxaaEnabled ? .postProcessingInput : .drawable,
            usesMultisampleResolve: renderSampleCount > 1
        )
    }
}
