// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

public enum LabelFontWeight: UInt8, Sendable {
    case bold = 0
    case thin = 1
}

enum LinePlacement {
    case ground
    case bridgeOverlay
}

enum RoadPassRole: Int, CaseIterable {
    case shadow
    case casing
    case fill
    case detail
    case overlay
}

struct LabelTextStyle {
    let key: Int
    let fillColor: SIMD3<Float>
    let strokeColor: SIMD3<Float>
    /// Halo width as a fraction of the em, so that it tracks the text size
    /// instead of drifting: an absolute width makes the smallest labels carry
    /// the widest halo relative to their strokes.
    let haloEm: Float
    /// Em size in layout points. Converted to device pixels once, at the render
    /// boundary (see `ScreenScale`).
    let sizePoints: Float
    let weight: LabelFontWeight

    /// Halo width in device pixels for this style at a given screen scale.
    func haloWidthPixels(screenScale: ScreenScale) -> Float {
        screenScale.pixels(haloEm * sizePoints)
    }
}

struct LineRenderPass {
    let key: UInt8
    let color: SIMD4<Float>
    let lowZoomFadeMask: Float
    let parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData
    let includeRoadLabelPath: Bool
    let placement: LinePlacement
    let roadPassRole: RoadPassRole

    init(key: UInt8,
         color: SIMD4<Float>,
         lowZoomFadeMask: Float = 0.0,
         parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData,
         includeRoadLabelPath: Bool,
         placement: LinePlacement = .ground,
         roadPassRole: RoadPassRole = .fill) {
        self.key = key
        self.color = color
        self.lowZoomFadeMask = lowZoomFadeMask
        self.parseGeometryStyleData = parseGeometryStyleData
        self.includeRoadLabelPath = includeRoadLabelPath
        self.placement = placement
        self.roadPassRole = roadPassRole
    }
}

struct FeatureStyle {
    let key: UInt8
    let color: SIMD4<Float>
    let lowZoomFadeMask: Float
    let parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData
    let includeRoadLabelPath: Bool
    let linePlacement: LinePlacement
    let lineRenderPasses: [LineRenderPass]
    let roadClassPriority: Int
    let usesExtrusion: Bool
    let extrusionHeightScale: Float
    let extrusionAnchorZoom: Int
    let extrusionFallbackHeight: Float
    let labelTextStyle: LabelTextStyle?
    let roadLabelTextStyle: LabelTextStyle?
    let roadDecorationKind: TileMvtParser.RoadDecorationKind
    /// Minimum CAMERA zoom for this feature's point label (0 = always visible).
    /// Travels with the label to runtime, where it is compared against the current camera zoom.
    let labelMinCameraZoom: Float
    /// A line style (e.g. a border) must not fill areal geometry: some layer
    /// features arrive as polygons (Native American reservations in `boundary`),
    /// and filling them with the line color is wrong. The parser skips the
    /// polygon geometry of such features, keeping only the lines.
    let suppressPolygonFill: Bool

    init(
        key: UInt8,
        color: SIMD4<Float>,
        lowZoomFadeMask: Float = 0.0,
        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData,
        includeRoadLabelPath: Bool = false,
        linePlacement: LinePlacement = .ground,
        lineRenderPasses: [LineRenderPass] = [],
        roadClassPriority: Int = 0,
        usesExtrusion: Bool = false,
        extrusionHeightScale: Float = 1.0,
        extrusionAnchorZoom: Int = 16,
        extrusionFallbackHeight: Float = 0,
        labelTextStyle: LabelTextStyle? = nil,
        roadLabelTextStyle: LabelTextStyle? = nil,
        roadDecorationKind: TileMvtParser.RoadDecorationKind = .none,
        labelMinCameraZoom: Float = 0,
        suppressPolygonFill: Bool = false
    ) {
        self.key = key
        self.color = color
        self.lowZoomFadeMask = lowZoomFadeMask
        self.parseGeometryStyleData = parseGeometryStyleData
        self.includeRoadLabelPath = includeRoadLabelPath
        self.linePlacement = linePlacement
        self.lineRenderPasses = lineRenderPasses
        self.roadClassPriority = roadClassPriority
        self.usesExtrusion = usesExtrusion
        self.extrusionHeightScale = extrusionHeightScale
        self.extrusionAnchorZoom = extrusionAnchorZoom
        self.extrusionFallbackHeight = extrusionFallbackHeight
        self.labelTextStyle = labelTextStyle
        self.roadLabelTextStyle = roadLabelTextStyle
        self.roadDecorationKind = roadDecorationKind
        self.labelMinCameraZoom = labelMinCameraZoom
        self.suppressPolygonFill = suppressPolygonFill
    }

    var resolvedLineRenderPasses: [LineRenderPass] {
        if lineRenderPasses.isEmpty == false {
            return lineRenderPasses
        }
        return [
            LineRenderPass(key: key,
                           color: color,
                           lowZoomFadeMask: lowZoomFadeMask,
                           parseGeometryStyleData: parseGeometryStyleData,
                           includeRoadLabelPath: includeRoadLabelPath,
                           placement: linePlacement,
                           roadPassRole: .fill)
        ]
    }
}
