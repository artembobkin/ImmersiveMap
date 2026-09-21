// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The depth and stencil states of the road sheet's two stages (Tile.metal):
/// the depth stage that gives each pixel to one style of the group, and the
/// colour stage that blends each pixel once.
struct RoadSheetStates {
    let depthStage: MTLDepthStencilState
    let colorStage: MTLDepthStencilState
}

/// Mirror of `RoadSheetUniform` in Tile.metal.
struct RoadSheetUniform {
    var baseDepth: Float
    var depthStep: Float
    var fringeDepth: Float
    var maximumRank: Float
    var bodyCoverage: Float
    var rankBias: Float
}

/// Where the road sheets sit in the flat rank-depth band. A sheet is what
/// blends once per pixel: one role of the roads that read as one network
/// (`FlatMapSurfaceDrawer`). Each takes a band of its own,
/// nearer than the group drawn before it, so a later group's bodies win
/// the depth stage over an earlier group's and paint over them, the
/// painter's order the groups had before they wrote depth.
///
/// A depth is an integer count of `depthStep` under one, and the step is a
/// power of two, so every value is exact in a float and the two stages,
/// compiled apart, compute the same bits for the equality the colour stage
/// tests.
enum RoadSheetDepth {
    /// Two units in the last place of a float under one.
    static let depthStep: Float = 0x1p-23
    /// The ranks of a sheet's band. A body's rank is its alpha, the more
    /// opaque the nearer, so the most opaque road owns a pixel several
    /// cover. The top rank is left to the colour stage's bias.
    static let ranksPerGroup = 63
    static let maximumAlphaRank = ranksPerGroup - 2
    /// The steps between the far ends of two groups' bands: the ranks and
    /// the far end itself, where the fringes sit.
    static let stepsPerGroup = ranksPerGroup + 1
    /// The first group's far end in steps under one: the flat road buckets'
    /// offset (`GlobeSurfaceDepthRank.flatRoadsDepthOffset`), rounded up to
    /// a whole step, so the sheet starts nearer than both ground bands.
    static let firstGroupSteps = Int((GlobeSurfaceDepthRank.flatRoadsDepthOffset / depthStep).rounded(.up))
    /// A body is a fragment the line covers whole. The depth stage's
    /// threshold is the stricter one (see `RoadSheetUniform.bodyCoverage`
    /// in Tile.metal).
    static let depthStageBodyCoverage: Float = 0.999
    static let colorStageBodyCoverage: Float = 0.99

    enum Stage {
        case depth
        case color
    }

    static func baseDepth(group: Int) -> Float {
        1 - Float(firstGroupSteps + group * stepsPerGroup) * depthStep
    }

    static func uniform(group: Int, stage: Stage) -> RoadSheetUniform {
        let base = baseDepth(group: group)
        switch stage {
        case .depth:
            // A fringe claims nothing in the depth stage: the far plane
            // fails the test against everything.
            return RoadSheetUniform(baseDepth: base,
                                    depthStep: depthStep,
                                    fringeDepth: 1,
                                    maximumRank: Float(maximumAlphaRank),
                                    bodyCoverage: depthStageBodyCoverage,
                                    rankBias: 0)
        case .color:
            return RoadSheetUniform(baseDepth: base,
                                    depthStep: depthStep,
                                    fringeDepth: base,
                                    maximumRank: Float(maximumAlphaRank),
                                    bodyCoverage: colorStageBodyCoverage,
                                    // One rank nearer: the stages may round
                                    // an alpha to neighbouring ranks.
                                    rankBias: 1)
        }
    }
}
