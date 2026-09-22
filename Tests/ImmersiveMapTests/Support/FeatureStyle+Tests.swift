// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd

/// One stroke of a style with its role, read the way the tests have always
/// read a pass: the role next to every field of the stroke.
@dynamicMemberLookup
struct TestRoadPass {
    let roadPassRole: RoadPassRole
    let pass: LinePass

    subscript<T>(dynamicMember keyPath: KeyPath<LinePass, T>) -> T {
        pass[keyPath: keyPath]
    }
}

/// The flat reading of a style the tests assert with: every stroke of a
/// road, and the fields of the style's main stroke or fill. Test-side only;
/// the engine switches over the cases.
extension FeatureStyle {
    var resolvedLineRenderPasses: [TestRoadPass] {
        roadStyle?.orderedPasses.map { TestRoadPass(roadPassRole: $0.role, pass: $0.pass) } ?? []
    }

    var lineRenderPasses: [TestRoadPass] {
        resolvedLineRenderPasses
    }

    /// The style's main stroke: a line's, a road's fill (or first stroke),
    /// and a fill or an extrusion as the stroke the parser bakes it to.
    var primaryPass: LinePass? {
        switch self {
        case .hidden: return nil
        case .fill(let fill): return BakedStyle(fill: fill).pass
        case .line(let line): return line.pass
        case .road(let road): return road.fill ?? road.orderedPasses.first?.pass
        case .extrusion(let extrusion): return BakedStyle(extrusion: extrusion).pass
        case .pointLabel: return nil
        }
    }

    var color: SIMD4<Float> { primaryPass?.color ?? SIMD4<Float>(0, 0, 0, 0) }
    var lowZoomFadeMask: Float { primaryPass?.lowZoomFadeMask ?? 0 }
    var lineWidthPoints: Float { primaryPass?.lineWidthPoints ?? 0 }
    var dashLengthPoints: Float { primaryPass?.dashLengthPoints ?? 0 }
    var dashGapPoints: Float { primaryPass?.dashGapPoints ?? 0 }
    var dashInTileUnits: Bool { primaryPass?.dashInTileUnits ?? false }
    var minimumWidthPoints: Float { primaryPass?.minimumWidthPoints ?? 0 }
    var lineGeometry: LineGeometryStyle { primaryPass?.lineGeometry ?? LineGeometryStyle(lineWidth: 0) }
    var suppressPolygonFill: Bool { lineStyle.map { $0.fillsAreas == false } ?? false }
    var splitsComplexHoles: Bool { fillStyle?.splitsComplexHoles ?? false }
    var isExtruded: Bool { extrusionStyle != nil }
    var extrusionFallbackHeight: Float { extrusionStyle?.fallbackHeight ?? 0 }
    var labelTextStyle: LabelTextStyle? { pointLabelStyle?.text }
    var labelMinCameraZoom: Float { pointLabelStyle?.minCameraZoom ?? 0 }
    var labelRank: Int { pointLabelStyle?.rank ?? 0 }
    var labelCollisionRank: Int { pointLabelStyle?.collisionRank ?? 0 }
    var roadLabelTextStyle: LabelTextStyle? { roadStyle?.label }
    var includeRoadLabelPath: Bool { roadStyle?.label != nil }
    var roadClassPriority: Int { roadStyle?.classPriority ?? 0 }
    var roadTier: RoadTier { roadStyle?.tier ?? .pedestrian }
    var roadDecorationKind: RoadDecorationKind { roadStyle?.decoration ?? .none }
    var surfaceAreaCutsPaint: Bool { (roadStyle?.surfacePaint ?? .keeps) != .keeps }
    var roadLevel: RoadLevel { roadStyle?.level ?? .ground }
}
