// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// One stretch of target zooms and the ring rules it is drawn by: from
/// `firstZoom` up to the zoom before the next set's first.
struct RingRuleSet: Hashable {
    var firstZoom: Int
    var rules: FlatRingRules
}

/// The ring rules by target zoom: any number of sets, each owning the
/// zooms from its first to the next set's, the last one to the deepest
/// zoom. A frame reads the set its target zoom falls in, so the globe's
/// zooms and the street zooms take different rules. The debug panel edits
/// the list.
struct RingRuleSets: Hashable {
    var sets: [RingRuleSet]

    static let zoomRange = 0 ... 22

    /// The target zooms the sphere and its unroll are drawn at under the
    /// default presentation settings, which finish the unroll at zoom 7.
    static let defaultStreetFirstZoom = 7

    /// The first zoom of the near street set, where the camera comes down
    /// among the buildings, and of the closest one.
    static let defaultNearStreetFirstZoom = 15
    static let defaultCloseStreetFirstZoom = 17

    /// Four sets. The globe's zooms step down fast and drop their lines
    /// early, since toward the limb a tile is seen edge on. The zooms past
    /// the unroll take the plane's rules (`FlatRingRules.default`). Among
    /// the buildings (`FlatRingRules.nearStreetDefault`) and closer still
    /// (`FlatRingRules.closeStreetDefault`) the rings shrink, since a tilted
    /// camera there sees the street and little else.
    static let `default` = RingRuleSets(sets: [
        RingRuleSet(firstZoom: 0, rules: .globeDefault),
        RingRuleSet(firstZoom: defaultStreetFirstZoom, rules: .default),
        RingRuleSet(firstZoom: defaultNearStreetFirstZoom, rules: .nearStreetDefault),
        RingRuleSet(firstZoom: defaultCloseStreetFirstZoom, rules: .closeStreetDefault)
    ])

    /// The sets as a frame reads them: first zooms inside the range, sorted,
    /// one set per first zoom, the first set starting at zoom 0, every
    /// set's rules normalized, at least one set.
    func normalized() -> RingRuleSets {
        var cleaned = sets.map { set in
            RingRuleSet(firstZoom: min(max(set.firstZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound),
                        rules: set.rules.normalized())
        }
        cleaned.sort { $0.firstZoom < $1.firstZoom }
        var unique: [RingRuleSet] = []
        for set in cleaned where unique.last.map({ $0.firstZoom < set.firstZoom }) ?? true {
            unique.append(set)
        }
        guard unique.isEmpty == false else { return .default }
        unique[0].firstZoom = Self.zoomRange.lowerBound
        return RingRuleSets(sets: unique)
    }

    /// The index of the set `zoom` falls in, of normalized sets. The frame
    /// asks by its camera zoom (`RenderFrameVisibilityResolver`).
    func setIndex(forZoom zoom: Int) -> Int {
        sets.lastIndex { $0.firstZoom <= zoom } ?? 0
    }

    /// The rules a frame at camera zoom `zoom` is drawn by.
    func rules(forZoom zoom: Int) -> FlatRingRules {
        let normalizedSets = normalized()
        return normalizedSets.sets[normalizedSets.setIndex(forZoom: zoom)].rules
    }

    /// The last zoom of the set at `index`, nil for the last set.
    func lastZoom(ofSetAt index: Int) -> Int? {
        sets.indices.contains(index + 1) ? sets[index + 1].firstZoom - 1 : nil
    }
}

extension FlatRingRules {
    /// The globe's zooms: the exact tiles with their lines to ring 1, then
    /// two levels coarser to ring 3 without lines. Ground past ring 3 is
    /// the pinned world cover (`GlobeTileCoverage`).
    static let globeDefault = FlatRingRules(rules: [
        FlatRingRule(zoomDrop: 0, distance: 1),
        FlatRingRule(zoomDrop: 2, distance: 3, drawsLines: false)
    ])

    /// Zooms 15 and 16: the exact tiles with their lines and labels to ring
    /// 1, one level coarser to ring 2 and five levels coarser to ring 3, both
    /// with their lines and without labels.
    static let nearStreetDefault = FlatRingRules(rules: [
        FlatRingRule(zoomDrop: 0, distance: 1),
        FlatRingRule(zoomDrop: 1, distance: 2, drawsLabels: false),
        FlatRingRule(zoomDrop: 5, distance: 3, drawsLabels: false)
    ])

    /// Zoom 17 and deeper: the exact tiles with their lines and labels to
    /// ring 1, then two levels coarser to ring 2 with their lines and
    /// without labels, nothing beyond.
    static let closeStreetDefault = FlatRingRules(rules: [
        FlatRingRule(zoomDrop: 0, distance: 1),
        FlatRingRule(zoomDrop: 2, distance: 2, drawsLabels: false)
    ])
}
