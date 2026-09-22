// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// What a rule set tunes besides its rules: the flat building fills'
/// footprint fade (`BuildingFootprintFade`: gone at the first area and
/// under, whole at the second and over), the roads' thinness fade and the
/// raster zone. The globe's zooms and the street zooms want different answers to
/// each, so they ride with the set.
struct RingRuleSetTuning: Hashable {
    var buildingGoneAreaPixels: Float = BuildingFootprintFade.defaultGoneAreaPixels
    var buildingOpaqueAreaPixels: Float = BuildingFootprintFade.defaultOpaqueAreaPixels
    var roadThinnessFade: RoadThinnessFade = .default
    var rasterZone: RasterZone = .default

    /// The areas in order: nothing is whole under the area it is gone at.
    func normalized() -> RingRuleSetTuning {
        var tuning = self
        tuning.buildingGoneAreaPixels = max(buildingGoneAreaPixels, 0)
        tuning.buildingOpaqueAreaPixels = max(buildingOpaqueAreaPixels, tuning.buildingGoneAreaPixels)
        return tuning
    }
}

extension RingRuleSetTuning {
    /// The globe's zooms: the pictures start nearer than the look-at point
    /// is, at 0.72 camera distances, since on the sphere the ground falls
    /// away from the camera on every side.
    static let globeDefault: RingRuleSetTuning = {
        var tuning = RingRuleSetTuning()
        tuning.rasterZone.startCameraDistances = 0.72
        return tuning
    }()
}

/// One stretch of target zooms, the ring rules it is drawn by and its
/// tuning: from `firstZoom` up to the zoom before the next set's first.
struct RingRuleSet: Hashable {
    var firstZoom: Int
    var rules: FlatRingRules
    var tuning = RingRuleSetTuning()
}

/// The ring rules by target zoom: any number of sets, each owning the
/// zooms from its first to the next set's, the last one to the deepest
/// zoom. A frame reads the set its target zoom falls in, so the globe's
/// zooms and the street zooms are tuned apart. The debug panel edits the
/// list.
struct RingRuleSets: Hashable {
    var sets: [RingRuleSet]

    static let zoomRange = 0 ... 22

    /// The target zooms the sphere and its unroll are drawn at under the
    /// default presentation settings, which finish the unroll at zoom 7.
    static let defaultStreetFirstZoom = 7

    /// Two sets. The globe's zooms step down fast and drop their lines
    /// early, since toward the limb a tile is seen edge on. The zooms past the unroll take the
    /// plane's rules (`FlatRingRules.default`).
    static let `default` = RingRuleSets(sets: [
        RingRuleSet(firstZoom: 0, rules: .globeDefault, tuning: .globeDefault),
        RingRuleSet(firstZoom: defaultStreetFirstZoom, rules: .default)
    ])

    /// The sets as a frame reads them: first zooms inside the range, sorted,
    /// one set per first zoom, the first set starting at zoom 0, every
    /// set's rules normalized, at least one set.
    func normalized() -> RingRuleSets {
        var cleaned = sets.map { set in
            RingRuleSet(firstZoom: min(max(set.firstZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound),
                        rules: set.rules.normalized(),
                        tuning: set.tuning.normalized())
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

    /// The index of the set `targetZoom` falls in, of normalized sets.
    func setIndex(forTargetZoom targetZoom: Int) -> Int {
        sets.lastIndex { $0.firstZoom <= targetZoom } ?? 0
    }

    /// The rules a frame at `targetZoom` is drawn by.
    func rules(forTargetZoom targetZoom: Int) -> FlatRingRules {
        let normalizedSets = normalized()
        return normalizedSets.sets[normalizedSets.setIndex(forTargetZoom: targetZoom)].rules
    }

    /// The tuning a frame at `targetZoom` is drawn with.
    func tuning(forTargetZoom targetZoom: Int) -> RingRuleSetTuning {
        let normalizedSets = normalized()
        return normalizedSets.sets[normalizedSets.setIndex(forTargetZoom: targetZoom)].tuning
    }

    /// The last zoom of the set at `index`, nil for the last set.
    func lastZoom(ofSetAt index: Int) -> Int? {
        sets.indices.contains(index + 1) ? sets[index + 1].firstZoom - 1 : nil
    }
}

extension FlatRingRules {
    /// The globe's zooms: the exact tiles with their lines to ring 1,
    /// pictured past the raster zone's start, then two levels coarser to
    /// ring 3, without lines and as geometry at every distance. Ground
    /// past ring 3 is the pinned world cover (`GlobeTileCoverage`).
    static let globeDefault = FlatRingRules(rules: [
        FlatRingRule(zoomDrop: 0, distance: 1, rasterized: true),
        FlatRingRule(zoomDrop: 2, distance: 3, drawsLines: false)
    ])
}
