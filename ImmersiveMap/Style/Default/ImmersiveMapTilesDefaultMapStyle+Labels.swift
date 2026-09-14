// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The labels: which point features of `place`, `water_name`, `poi` and
/// the rest become labels at which tile zoom, how they rank against each
/// other, and how each is drawn. The road names too.
extension ImmersiveMapTilesDefaultMapStyle {
    /// The point labels of the coarse zooms are a short list: continents,
    /// countries and oceans up to z2, the major places to z4.
    static let lowZoomOverviewMaximumTileZoom = 4
    static let poiMinimumZoom = 13

    /// OSM street furniture that must never become a label at any zoom:
    /// bicycle racks, waste baskets, gates, building entrances, etc.
    /// Such classes amount to thousands of features per tile and only clutter collisions.
    static let excludedPoiClasses: Set<String> = [
        "bicycle_parking", "waste_basket", "gate", "entrance", "bench",
        "drinking_water", "toilets", "vending_machine", "recycling"
    ]

    /// Cap on the local rank: rank is computed within a ~128px grid cell of
    /// the tile, so the threshold means "no more than N labels per cell".
    /// The tail beyond the cap never even reaches the buffers: in a dense
    /// center that is thousands of features per tile. The number is aligned
    /// with the reveal schedule (cell budget quadrupled by overzoom): 64 =
    /// 4^3, i.e. the cap holds exactly what the schedule can show by
    /// tile.z + 3.
    static let maximumPoiRank = 64

    /// A feature without a rank is the least important thing in its layer.
    /// `rank` is 1-based (1 = biggest) and is the whole contract the tiles
    /// follow (the label-priority contract): the tiles bake population and
    /// capital status into it at build time, so there is no second signal
    /// to reconcile.
    static let unrankedLabelRank = 1_000

    /// Lower value == more important.
    func labelRank(_ props: [String: MvtValue]) -> Int {
        parseIntValue(props["rank"]) ?? Self.unrankedLabelRank
    }

    /// Places beat water names beat peaks and airports beat POIs whatever
    /// their ranks.
    static func labelCollisionRank(layer: String, rank: Int) -> Int {
        switch layer {
        case "place":
            return rank
        case "water_name":
            return 20_000 + rank
        case "mountain_peak", "aerodrome_label":
            return 40_000 + rank
        case "poi":
            return 50_000 + rank
        default:
            return rank
        }
    }

    func includesPlaceLabel(props: [String: MvtValue], tileZoom: Int) -> Bool {
        let cls = props["class"]?.stringValue?.lowercased()
        // Continents/countries/oceans dominate the very low zooms.
        if tileZoom <= 2 {
            return cls == "continent" || cls == "country" || cls == "ocean"
        }
        // z3: only countries, major cities and capitals - drop the dense
        // province/state ("... Oblast") labels that otherwise flood this zoom.
        if tileZoom == 3 {
            switch cls {
            case "continent", "country", "city":
                return true
            default:
                return isCapital(props)
            }
        }
        if tileZoom <= Self.lowZoomOverviewMaximumTileZoom {
            switch cls {
            case "continent", "country", "state", "province", "city":
                return true
            default:
                return isCapital(props)
            }
        }
        return true
    }

    func includesWaterLabel(props: [String: MvtValue], tileZoom: Int) -> Bool {
        guard tileZoom <= Self.lowZoomOverviewMaximumTileZoom else { return true }
        switch props["class"]?.stringValue?.lowercased() {
        case "ocean", "sea":
            return true
        default:
            return false
        }
    }

    func includesPoiLabel(props: [String: MvtValue], tileZoom: Int) -> Bool {
        guard tileZoom >= Self.poiMinimumZoom else {
            return false
        }
        if let poiClass = props["class"]?.stringValue?.lowercased(),
           Self.excludedPoiClasses.contains(poiClass) {
            return false
        }
        if let rank = parseIntValue(props["rank"]), rank > Self.maximumPoiRank {
            return false
        }
        return true
    }

    func isCapital(_ props: [String: MvtValue]) -> Bool {
        // `capital` = 2 (national), 3/4 (regional) when present.
        if let capital = parseIntValue(props["capital"]), capital > 0 {
            return true
        }
        return false
    }

    func placeLabelStyle(props: [String: MvtValue]) -> FeatureStyle {
        let cls = props["class"]?.stringValue?.lowercased()
        var appearance: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance
        switch cls {
        case "continent", "country":
            appearance = configuration.labels.country
        case "state", "province":
            var a = configuration.labels.country
            a.sizePoints -= 2
            appearance = a
        case "city":
            appearance = configuration.labels.city
        case "town":
            appearance = configuration.labels.town
        default: // village, hamlet, suburb, quarter, neighbourhood, ...
            var a = configuration.labels.town
            a.sizePoints -= 1.5
            a.weight = .thin
            appearance = a
        }
        // Capitals in the label-priority contract: `capital` no longer
        // travels in the tiles, a national capital is a rank-1 city.
        if cls == "city", parseIntValue(props["rank"]) == 1 {
            appearance.sizePoints += 1.5
            appearance.weight = .bold
        }
        return pointLabel(key: 70, layer: "place", props: props, appearance: appearance)
    }

    func waterLabelStyle(props: [String: MvtValue]) -> FeatureStyle {
        var appearance = configuration.labels.water
        switch props["class"]?.stringValue?.lowercased() {
        case "ocean":
            appearance.sizePoints += 3
        case "sea":
            appearance.sizePoints += 1.5
        default:
            break
        }
        return pointLabel(key: 73, layer: "water_name", props: props, appearance: appearance)
    }

    // POI: both the icon circle and the label are tinted in the venue category
    // color. The color flows through LabelTextStyle.fillColor, used by both the
    // icon background (PoiIconStyleUniform.backgroundColor) and the text fill;
    // the icon glyph is white. All POIs share one key (72): runs are grouped by
    // full style identity (weight + colors), so different categories land in
    // separate draw runs.
    func poiLabelStyle(props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        // POI appearance is derived from budget and priorities, with no
        // absolute zoom ramps: a label is visible once its effective rank fits
        // the grid-cell budget, and the budget quadruples with each zoom of
        // overzoom, exactly like the tile's screen area. The decision collapses
        // into a static threshold minCameraZoom = tile.z + log4(effRank / budget),
        // which the runtime and collisions apply by camera zoom. Classes define
        // a priority offset in rank units rather than zooms, so the approach
        // does not depend on the source maxzoom: switching sources shifts the
        // thresholds automatically via tile.z.
        let cls = props["class"]?.stringValue?.lowercased()
        let subclass = props["subclass"]?.stringValue?.lowercased()
        let rank = Double(parseIntValue(props["rank"]) ?? Self.poiUnrankedRank)
        let effectiveRank = max(Self.poiNativeCellBudget,
                                rank + Self.poiClassRankBias(cls: cls, subclass: subclass))
        var minCameraZoom = Float(tileZoom)
            + Float(log2(effectiveRank / Self.poiNativeCellBudget) / 2.0)
        let icon = Self.poiIcon(props: props)
        if icon == nil {
            // A category the icon set does not know (an office, a company, a
            // monument, a named building) has nothing to draw but its name,
            // and in a city centre those names outnumber everything else: bare
            // text over the buildings, saying nothing about what the place is.
            // By default they are left out entirely; a configuration that
            // wants them back gets them from the iconless zoom floor.
            guard configuration.labelVisibility.poiRequiresIcon == false else {
                return hiddenStyle
            }
            minCameraZoom = max(minCameraZoom, Float(configuration.labelVisibility.poiIconlessMinimumZoom))
        }
        minCameraZoom = min(minCameraZoom, Float(tileZoom) + Self.poiMaximumOverzoomAppearanceDelay)
        // The global POI floor comes after the overzoom-delay cap on purpose:
        // the cap bounds rank-derived delays, while the floor is an absolute
        // visibility gate that may exceed it (up to hiding POIs entirely).
        minCameraZoom = max(minCameraZoom, Float(configuration.labelVisibility.poiMinimumZoom))

        var appearance = configuration.labels.poi
        appearance.fillColor = poiCategoryColor(cls: cls, subclass: subclass)
        return pointLabel(key: 72, layer: "poi", props: props, appearance: appearance,
                          minCameraZoom: minCameraZoom, icon: icon)
    }

    /// The sprite a POI draws beside its name: the first of `maki`,
    /// `class`, `type` and `subclass` the icon set knows a symbol for. Nil
    /// for a category with no symbol, which draws as text alone or not at
    /// all (`poiRequiresIcon`).
    static func poiIcon(props: [String: MvtValue]) -> PoiSpriteIcon? {
        for key in ["maki", "class", "type", "subclass"] {
            guard let value = props[key]?.stringValue, let icon = poiIcon(category: value) else { continue }
            return icon
        }
        return nil
    }

    private static func poiIcon(category: String) -> PoiSpriteIcon? {
        let normalized = category
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "restaurant", "fast_food", "food_court":
            return .restaurant
        case "cafe", "coffee", "tea", "bakery":
            return .cafe
        case "bar", "pub", "beer", "alcohol":
            return .bar
        case "park", "garden", "national_park", "dog_park":
            return .park
        case "museum", "gallery", "arts", "art_gallery":
            return .museum
        case "hospital", "clinic", "doctor", "dentist", "healthcare":
            return .hospital
        case "school", "college", "university", "kindergarten", "library":
            return .school
        case "airport", "airfield", "aerodrome", "heliport":
            return .airport
        case "stadium", "sport", "sports_centre", "soccer", "basketball", "pitch":
            return .stadium
        case "lodging", "hotel", "hostel", "guest_house":
            return .hotel
        case "shop", "grocery", "supermarket", "mall", "clothing_store", "convenience":
            return .shopping
        case "fuel", "gas_station", "charging_station":
            return .gasStation
        case "pharmacy", "chemist":
            return .pharmacy
        case "viewpoint", "attraction", "tourism":
            return .viewpoint
        default:
            return nil
        }
    }

    /// Rank grid-cell budget at the tile's NATIVE zoom: rank <= budget is
    /// visible as soon as the tile appears; each zoom of overzoom quadruples the budget.
    static let poiNativeCellBudget = 1.0

    /// Rank for features without a rank attribute. The label-priority contract
    /// says an absent rank means the least important thing in its layer, so it
    /// lands at the reveal cap's tail (the profile's rank cap), not mid-tail.
    static let poiUnrankedRank = 64

    /// Reveal ceiling: the neutral tail of the cap (rank 64) is exhausted
    /// exactly by tile.z + 3; positively offset infrastructure is clamped to
    /// arrive by tile.z + 3.5. There is nothing left to pull from the tile deeper than that.
    static let poiMaximumOverzoomAppearanceDelay: Float = 3.5

    /// Class priority offsets in rank units (zoom-agnostic). Anchors are
    /// pushed negative and visible from the tile's birth, urban fabric comes
    /// slightly before neutral commerce, decorative greenery slightly later,
    /// street infrastructure ~two zooms later than the neutral classes.
    static let poiMajorClasses: Set<String> = [
        "hospital", "railway", "aerodrome", "university", "college", "stadium",
        "museum", "zoo", "attraction", "harbor", "monument", "castle"
    ]

    static let poiCommunityClasses: Set<String> = [
        "school", "theatre", "cinema", "lodging", "town_hall", "townhall",
        "library", "police", "fire_station", "pharmacy", "grocery", "park",
        "place_of_worship", "post", "bank", "campsite"
    ]

    static let poiLateClasses: Set<String> = [
        "garden", "playground", "swimming_pool", "kindergarten", "sport"
    ]

    static let poiInfrastructureClasses: Set<String> = [
        "bus", "bicycle_rental", "bicycle_rent", "parking", "fuel",
        "charging_station", "car", "car_rental", "atm"
    ]

    static func poiClassRankBias(cls: String?, subclass: String?) -> Double {
        func bias(_ value: String?) -> Double? {
            guard let value else { return nil }
            if poiMajorClasses.contains(value) { return -1_000 }
            if poiCommunityClasses.contains(value) { return -4 }
            if poiLateClasses.contains(value) { return 8 }
            if poiInfrastructureClasses.contains(value) { return 40 }
            return nil
        }
        return bias(subclass) ?? bias(cls) ?? 0
    }

    func poiCategoryColor(cls: String?, subclass: String?) -> SIMD3<Float> {
        switch cls ?? subclass {
        case "restaurant", "fast_food", "food_court", "ice_cream":
            return SIMD3<Float>(0.85, 0.40, 0.12)   // food: orange
        case "cafe", "bakery":
            return SIMD3<Float>(0.58, 0.37, 0.18)   // coffee/bakery: brown
        case "bar", "pub", "beer", "alcohol_shop", "nightclub", "wine":
            return SIMD3<Float>(0.62, 0.16, 0.34)   // bar: wine red
        case "shop", "grocery", "supermarket", "mall", "clothing_store", "convenience",
             "gift", "hairdresser", "hardware", "laundry", "car", "florist", "jewelry", "shoe":
            return SIMD3<Float>(0.16, 0.44, 0.78)   // shops: blue
        case "lodging":
            return SIMD3<Float>(0.66, 0.26, 0.60)   // hotels: magenta
        case "hospital", "pharmacy", "doctors", "dentist", "clinic":
            return SIMD3<Float>(0.82, 0.22, 0.26)   // health: red
        case "school", "college", "university", "kindergarten", "library":
            return SIMD3<Float>(0.22, 0.46, 0.52)   // education: teal
        case "museum", "art_gallery", "gallery", "attraction", "artwork", "theatre", "music", "cinema":
            return SIMD3<Float>(0.46, 0.30, 0.66)   // culture: violet
        case "park", "garden", "stadium", "pitch", "sport", "swimming", "golf", "playground", "picnic_site":
            return SIMD3<Float>(0.22, 0.54, 0.30)   // leisure/nature: green
        case "bus", "railway", "airport", "aerialway", "fuel", "car_rental", "parking", "harbor", "ferry_terminal":
            return SIMD3<Float>(0.32, 0.42, 0.55)   // transport: blue-gray
        case "bank", "post", "office", "town_hall", "police", "fire_station", "government", "atm":
            return SIMD3<Float>(0.40, 0.44, 0.52)   // offices/public services: gray-blue
        default:
            return configuration.labels.poi.fillColor  // everything else: default dark
        }
    }

    /// The road names ship as their own lines: an invisible hairline
    /// carries the name along it.
    func roadLabelStyle(cls: String?) -> FeatureStyle {
        .road(RoadStyle(
            fill: LinePass(key: 90,
                           color: SIMD4<Float>(0, 0, 0, 0),
                           lineGeometry: LineGeometryStyle(lineWidth: 1)),
            classPriority: roadLabelPriority(cls: cls),
            label: labelTextStyle(key: 90, appearance: configuration.labels.road)
        ))
    }

    func houseNumberAppearance() -> ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance {
        var appearance = configuration.labels.poi
        // The densest label class, and the one the readable floor moves most:
        // 6 points was decoration rather than information, and at the floor each
        // one is legible while collision thins out the rest.
        appearance.sizePoints = 6
        appearance.fillColor = SIMD3<Float>(0.55, 0.53, 0.50)
        return appearance
    }

    func pointLabel(key: UInt8,
                    layer: String,
                    props: [String: MvtValue],
                    appearance: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance,
                    minCameraZoom: Float = 0,
                    icon: PoiSpriteIcon? = nil) -> FeatureStyle {
        let rank = labelRank(props)
        return FeatureStyle.pointLabel(key: key,
                                       labelTextStyle(key: Int(key), appearance: appearance),
                                       rank: rank,
                                       collisionRank: Self.labelCollisionRank(layer: layer, rank: rank),
                                       minCameraZoom: minCameraZoom,
                                       icon: icon)
    }

    func labelTextStyle(key: Int,
                        appearance: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance) -> LabelTextStyle {
        LabelTextStyle(key: key,
                       fillColor: appearance.fillColor,
                       strokeColor: appearance.strokeColor,
                       haloEm: appearance.haloEm,
                       sizePoints: LabelTypeScale.clamped(appearance.sizePoints),
                       weight: appearance.weight)
    }

    func roadLabelPriority(cls: String?) -> Int {
        switch cls {
        case "motorway": return 95
        case "trunk": return 90
        case "primary": return 80
        case "secondary": return 78
        case "tertiary": return 74
        case "minor": return 50
        default: return 30
        }
    }
}
