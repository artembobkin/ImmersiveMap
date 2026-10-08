// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// How far from the camera the labels show over one stretch of camera
/// zooms: from `firstZoom` up to the zoom before the next rule's first.
struct LabelDistanceRule: Hashable {
    var firstZoom: Int
    /// In multiples of the camera's distance to the point it looks at,
    /// point labels and road names alike. A label farther than that fades
    /// out, and comes back as the camera nears it. Measured along the view:
    /// a camera looking straight down has every label at about one such
    /// distance and keeps them all, a tilted one lets the labels up toward
    /// the horizon go. A road name goes whole once any of its letters is
    /// past the distance. `.infinity` keeps every label.
    var scale: Float

    static let defaultScale: Float = 1.25
}

/// The labels' reach by camera zoom: any number of rules, each owning the
/// zooms from its first to the next rule's, the last one to the deepest
/// zoom. A frame reads the rule its camera zoom falls in
/// (`BaseLabelPrepareSubsystem`), the debug panel edits the list. Apart
/// from the ring rules (`RingRuleSets`): the zooms where the labels reach
/// farther or nearer are not the zooms where the tile rings change.
struct LabelDistanceRules: Hashable {
    var rules: [LabelDistanceRule]

    static let zoomRange = 0 ... 22

    /// Three rules. Up to zoom 13 the map is seen from afar and the labels
    /// reach five times the camera's distance to the point it looks at.
    /// From zoom 14 the camera is among the streets, and a tilt would
    /// carry the labels up the street to the horizon: they reach a quarter
    /// past that distance. From zoom 18 the camera stands so close to the
    /// ground that a quarter past its distance ends a few houses away, and
    /// the labels reach twice it.
    static let `default` = LabelDistanceRules(rules: [
        LabelDistanceRule(firstZoom: 0, scale: 5),
        LabelDistanceRule(firstZoom: 14, scale: LabelDistanceRule.defaultScale),
        LabelDistanceRule(firstZoom: 18, scale: 2)
    ])

    /// The rules as a frame reads them: first zooms inside the range,
    /// sorted, one rule per first zoom, the first rule starting at zoom 0,
    /// no negative or undefined reach, at least one rule.
    func normalized() -> LabelDistanceRules {
        var cleaned = rules.map { rule in
            LabelDistanceRule(firstZoom: min(max(rule.firstZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound),
                              scale: rule.scale.isNaN ? LabelDistanceRule.defaultScale : max(rule.scale, 0))
        }
        cleaned.sort { $0.firstZoom < $1.firstZoom }
        var unique: [LabelDistanceRule] = []
        for rule in cleaned where unique.last.map({ $0.firstZoom < rule.firstZoom }) ?? true {
            unique.append(rule)
        }
        guard unique.isEmpty == false else { return .default }
        unique[0].firstZoom = Self.zoomRange.lowerBound
        return LabelDistanceRules(rules: unique)
    }

    /// The zoom a frame's rule is chosen by: the camera zoom's whole part.
    static func ruleZoom(cameraZoom: Double) -> Int {
        guard cameraZoom.isFinite else { return zoomRange.lowerBound }
        return min(max(zoomRange.lowerBound, Int(cameraZoom.rounded(.down))), zoomRange.upperBound)
    }

    /// The reach at a camera zoom, of normalized rules.
    func scale(forCameraZoom cameraZoom: Double) -> Float {
        let zoom = Self.ruleZoom(cameraZoom: cameraZoom)
        return (rules.last { $0.firstZoom <= zoom } ?? rules.first)?.scale ?? LabelDistanceRule.defaultScale
    }

    /// The last zoom of the rule at `index`, nil for the last rule.
    func lastZoom(ofRuleAt index: Int) -> Int? {
        rules.indices.contains(index + 1) ? rules[index + 1].firstZoom - 1 : nil
    }
}
