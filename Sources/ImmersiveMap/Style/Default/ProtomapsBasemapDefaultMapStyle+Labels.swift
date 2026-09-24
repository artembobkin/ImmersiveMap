// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The labels: which point features of `places`, `water` and `pois` become
/// labels at which tile zoom, how they rank against each other, and how
/// each is drawn. The road names are laid along the roads themselves
/// (`roadStyle`).
extension ProtomapsBasemapDefaultMapStyle {
    /// The point labels of the coarse zooms are a short list: the
    /// countries up to z2, the countries and the major cities at z3, the
    /// oceans up to z4.
    static let lowZoomOverviewMaximumTileZoom = 4
    /// The tile zoom the POIs join from. The basemap ships the biggest of
    /// them (an airport, a national park) much earlier, but over a region
    /// view they compete with the places for the same room.
    static let poiMinimumTileZoom = 13
    /// The peaks and the airports are landmarks of a region view and join
    /// before the rest of the POIs.
    static let landmarkPoiMinimumTileZoom = 8

    /// OSM street furniture that must never become a label at any zoom:
    /// bicycle racks, waste baskets, gates, building entrances, bus stops.
    /// Such kinds amount to thousands of features per tile and only clutter
    /// collisions.
    static let excludedPoiKinds: Set<String> = [
        "bicycle_parking", "waste_basket", "gate", "entrance", "bench",
        "drinking_water", "toilets", "vending_machine", "recycling",
        "bus_stop", "parking", "atm"
    ]

    /// A feature without a rank is the least important thing in its layer.
    static let unrankedLabelRank = 1_000

    /// A place's importance, lower first: the basemap's `population_rank`
    /// (0 to 17, higher is bigger) turned around, and the kind of place
    /// breaking the ties, a country before its regions before its towns.
    func placeRank(kind: String?, props: [String: MvtValue]) -> Int {
        guard let populationRank = parseIntValue(props["population_rank"]) else {
            return Self.unrankedLabelRank
        }
        let kindOffset: Int
        switch kind {
        case "country": kindOffset = 0
        case "region": kindOffset = 1
        case "locality": kindOffset = 2
        case "macrohood": kindOffset = 3
        default: kindOffset = 4
        }
        return max(0, 18 - populationRank) * 10 + kindOffset
    }

    /// A water body's or a POI's importance: the tile zoom the basemap
    /// ships it from, then its `sort_rank`.
    func minZoomRank(props: [String: MvtValue]) -> Int {
        guard let minZoom = parseIntValue(props["min_zoom"]) else {
            return Self.unrankedLabelRank
        }
        return minZoom * 100 + (parseIntValue(props["sort_rank"]) ?? 0)
    }

    /// The collision bands: places beat water names beat peaks and airports
    /// beat the other POIs whatever their ranks.
    enum LabelBand {
        case place
        case water
        case landmark
        case poi

        var base: Int {
            switch self {
            case .place: return 0
            case .water: return 20_000
            case .landmark: return 40_000
            case .poi: return 50_000
            }
        }
    }

    static func labelCollisionRank(band: LabelBand, rank: Int) -> Int {
        band.base + rank
    }

    /// The tile zoom a kind of place is shown from when the tile states no
    /// `min_zoom` for it.
    static func placeFallbackMinimumZoom(kind: String?) -> Int {
        switch kind {
        case "country": return 0
        case "region": return 4
        case "locality": return 5
        default: return 12
        }
    }

    func includesPlaceLabel(kind: String?, kindDetail: String?, props: [String: MvtValue], tileZoom: Int) -> Bool {
        // Countries dominate the very low zooms.
        if tileZoom <= 2 {
            return kind == "country"
        }
        // z3: countries, the cities and the capitals, and not the dense
        // region labels that otherwise flood this zoom.
        if tileZoom == 3 {
            if kind == "country" {
                return true
            }
            return kind == "locality" && (kindDetail == "city" || isCapital(props))
        }
        let minimumZoom = parseIntValue(props["min_zoom"]) ?? Self.placeFallbackMinimumZoom(kind: kind)
        return tileZoom >= minimumZoom
    }

    func includesWaterLabel(kind: String?, tileZoom: Int) -> Bool {
        guard tileZoom <= Self.lowZoomOverviewMaximumTileZoom else { return true }
        // The basemap files the seas under the ocean kind as well.
        return kind == "ocean"
    }

    func includesPoiLabel(kind: String?, tileZoom: Int) -> Bool {
        let minimumZoom = Self.isLandmarkPoi(kind: kind) ? Self.landmarkPoiMinimumTileZoom : Self.poiMinimumTileZoom
        guard tileZoom >= minimumZoom else {
            return false
        }
        if let kind, Self.excludedPoiKinds.contains(kind) {
            return false
        }
        return true
    }

    /// The `capital` attribute is the raw OSM value, present on a capital
    /// of any level.
    func isCapital(_ props: [String: MvtValue]) -> Bool {
        guard let capital = props["capital"]?.stringValue?.lowercased() else {
            return parseIntValue(props["capital"]).map { $0 > 0 } ?? false
        }
        return capital.isEmpty == false && capital != "no"
    }

    func placeLabelStyle(kind: String?, kindDetail: String?, props: [String: MvtValue]) -> FeatureStyle {
        var appearance: ProtomapsBasemapTheme.LabelAppearance
        switch kind {
        case "country":
            appearance = theme.labels.country
        case "region":
            var a = theme.labels.country
            a.sizePoints -= 2
            appearance = a
        case "locality":
            switch kindDetail {
            case "city":
                appearance = theme.labels.city
            case "town":
                appearance = theme.labels.town
            default: // village, hamlet, and the rest
                var a = theme.labels.town
                a.sizePoints -= 1.5
                a.weight = .thin
                appearance = a
            }
        default: // macrohood, neighbourhood
            var a = theme.labels.town
            a.sizePoints -= 1.5
            a.weight = .thin
            appearance = a
        }
        // A national capital is a city carrying the `capital` attribute.
        if kind == "locality", kindDetail == "city", isCapital(props) {
            appearance.sizePoints += 1.5
            appearance.weight = .bold
        }
        let rank = placeRank(kind: kind, props: props)
        return pointLabel(key: 70, band: .place, rank: rank, appearance: appearance)
    }

    /// A water body's name lies on the water: it turns and tilts with the
    /// map and grows with the zoom, the way an atlas letters a sea. It is
    /// ink on the water rather than a label over it: no halo, a deeper blue
    /// of the water's own hue (the theme's water label), the letters spaced
    /// out.
    func waterLabelStyle(kind: String?, props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        var appearance = theme.labels.water
        if kind == "ocean" {
            appearance.sizePoints += 3
        }
        let minimumZoom = parseIntValue(props["min_zoom"]) ?? tileZoom
        return pointLabel(key: 73,
                          band: .water,
                          rank: minZoomRank(props: props),
                          appearance: appearance,
                          placement: .surface(Self.waterLabelSurfacePlacement(minimumZoom: minimumZoom)))
    }

    /// Where a water name painted on the map shows. The basemap ships the
    /// name from the tile zoom `minimumZoom`, which the engine draws from
    /// that camera zoom on: the name shows from there at its point size,
    /// grows with the map from half a zoom in, and is gone two zooms in,
    /// before it outgrows the water it names.
    static func waterLabelSurfacePlacement(minimumZoom: Int) -> SurfaceLabelPlacement {
        let start = Double(max(minimumZoom, 0))
        return SurfaceLabelPlacement(referenceZoom: start + 0.5,
                                     minimumZoom: start,
                                     maximumZoom: start + 2,
                                     letterSpacingEm: waterLabelLetterSpacingEm)
    }

    /// The tracking of a water name, in ems.
    static let waterLabelLetterSpacingEm: Float = 0.15

    /// The landmarks among the POIs: the peaks and the airports, which take
    /// their own keys and collision band.
    static func isLandmarkPoi(kind: String?) -> Bool {
        switch kind {
        case "peak", "volcano", "aerodrome":
            return true
        default:
            return false
        }
    }

    // POI: both the icon circle and the label are tinted in the venue category
    // color. The color flows through LabelTextStyle.fillColor, used by both the
    // icon background (PoiIconStyleUniform.backgroundColor) and the text fill;
    // the icon glyph is white. All POIs share one key (72): runs are grouped by
    // full style identity (weight + colors), so different categories land in
    // separate draw runs.
    func poiLabelStyle(kind: String?, props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        // The basemap states per POI the tile zoom it belongs to
        // (`min_zoom`, from the feature's prominence), and every tile from
        // there carries it. The label appears with the camera at that zoom
        // and never before the tile it rides: a static threshold the
        // runtime and the collisions apply by camera zoom.
        let icon = Self.poiIcon(kind: kind)
        let isLandmark = Self.isLandmarkPoi(kind: kind)
        var minCameraZoom = Float(tileZoom)
        if isLandmark == false || kind != "aerodrome" {
            minCameraZoom = max(minCameraZoom, Float(parseIntValue(props["min_zoom"]) ?? Self.poiUnstatedMinimumZoom))
        }
        if icon == nil {
            // A category the icon set does not know (an office, a company, a
            // monument, a named building) has nothing to draw but its name,
            // and in a city centre those names outnumber everything else: bare
            // text over the buildings, saying nothing about what the place is.
            // By default they are left out entirely; a theme that
            // wants them back gets them from the iconless zoom floor.
            guard theme.labelVisibility.poiRequiresIcon == false else {
                return hiddenStyle
            }
            minCameraZoom = max(minCameraZoom, Float(theme.labelVisibility.poiIconlessMinimumZoom))
        }
        // The global POI floor is an absolute visibility gate that may
        // exceed everything above (up to hiding POIs entirely).
        minCameraZoom = max(minCameraZoom, Float(theme.labelVisibility.poiMinimumZoom))

        var appearance = theme.labels.poi
        appearance.fillColor = poiCategoryColor(kind: kind)
        let key: UInt8
        switch kind {
        case "peak", "volcano": key = 74
        case "aerodrome": key = 75
        default: key = 72
        }
        return pointLabel(key: key,
                          band: isLandmark ? .landmark : .poi,
                          rank: minZoomRank(props: props),
                          appearance: appearance,
                          minCameraZoom: minCameraZoom,
                          icon: icon)
    }

    /// The zoom a POI without a stated `min_zoom` is taken to belong to:
    /// past the basemap's deepest tile, so it only ever shows overzoomed.
    static let poiUnstatedMinimumZoom = 16

    /// The sprite a POI draws beside its name, from its `kind`, the raw OSM
    /// value. Nil for a category with no symbol, which draws as text alone
    /// or not at all (`poiRequiresIcon`).
    static func poiIcon(kind: String?) -> PoiSpriteIcon? {
        switch kind {
        case "restaurant", "fast_food", "food_court":
            return .restaurant
        case "cafe", "bakery":
            return .cafe
        case "bar", "pub", "biergarten", "nightclub":
            return .bar
        case "park", "garden", "national_park", "nature_reserve", "dog_park":
            return .park
        case "museum", "gallery", "artwork":
            return .museum
        case "hospital", "clinic", "doctors", "dentist":
            return .hospital
        case "school", "college", "university", "kindergarten", "library":
            return .school
        case "aerodrome", "airfield", "heliport":
            return .airport
        case "stadium", "sports_centre", "pitch":
            return .stadium
        case "hotel", "hostel", "guest_house", "motel":
            return .hotel
        case "supermarket", "mall", "convenience", "department_store", "marketplace":
            return .shopping
        case "fuel", "charging_station":
            return .gasStation
        case "pharmacy", "chemist":
            return .pharmacy
        case "viewpoint", "attraction", "peak", "volcano":
            return .viewpoint
        default:
            return nil
        }
    }

    func poiCategoryColor(kind: String?) -> SIMD3<Float> {
        switch kind {
        case "restaurant", "fast_food", "food_court", "ice_cream":
            return SIMD3<Float>(0.85, 0.40, 0.12)   // food: orange
        case "cafe", "bakery":
            return SIMD3<Float>(0.58, 0.37, 0.18)   // coffee/bakery: brown
        case "bar", "pub", "biergarten", "nightclub", "wine":
            return SIMD3<Float>(0.62, 0.16, 0.34)   // bar: wine red
        case "supermarket", "mall", "convenience", "department_store", "marketplace",
             "gift", "hairdresser", "hardware", "laundry", "florist", "jewelry", "shoes", "clothes":
            return SIMD3<Float>(0.16, 0.44, 0.78)   // shops: blue
        case "hotel", "hostel", "guest_house", "motel":
            return SIMD3<Float>(0.66, 0.26, 0.60)   // hotels: magenta
        case "hospital", "pharmacy", "chemist", "doctors", "dentist", "clinic":
            return SIMD3<Float>(0.82, 0.22, 0.26)   // health: red
        case "school", "college", "university", "kindergarten", "library":
            return SIMD3<Float>(0.22, 0.46, 0.52)   // education: teal
        case "museum", "gallery", "attraction", "artwork", "theatre", "cinema":
            return SIMD3<Float>(0.46, 0.30, 0.66)   // culture: violet
        case "park", "garden", "national_park", "nature_reserve", "dog_park",
             "stadium", "pitch", "sports_centre", "swimming_pool", "golf_course", "playground", "picnic_site":
            return SIMD3<Float>(0.22, 0.54, 0.30)   // leisure/nature: green
        case "station", "aerodrome", "airfield", "heliport", "fuel", "charging_station",
             "car_rental", "ferry_terminal", "harbour":
            return SIMD3<Float>(0.32, 0.42, 0.55)   // transport: blue-gray
        case "bank", "post_office", "townhall", "police", "fire_station", "government":
            return SIMD3<Float>(0.40, 0.44, 0.52)   // offices/public services: gray-blue
        default:
            return theme.labels.poi.fillColor  // everything else: default dark
        }
    }

    func pointLabel(key: UInt8,
                    band: LabelBand,
                    rank: Int,
                    appearance: ProtomapsBasemapTheme.LabelAppearance,
                    minCameraZoom: Float = 0,
                    icon: PoiSpriteIcon? = nil,
                    placement: LabelPlacement = .screen) -> FeatureStyle {
        FeatureStyle.pointLabel(key: key,
                                labelTextStyle(key: Int(key), appearance: appearance),
                                rank: rank,
                                collisionRank: Self.labelCollisionRank(band: band, rank: rank),
                                minCameraZoom: minCameraZoom,
                                icon: icon,
                                placement: placement)
    }

    func labelTextStyle(key: Int,
                        appearance: ProtomapsBasemapTheme.LabelAppearance) -> LabelTextStyle {
        LabelTextStyle(key: key,
                       fillColor: appearance.fillColor,
                       strokeColor: appearance.strokeColor,
                       haloEm: appearance.haloEm,
                       sizePoints: LabelTypeScale.clamped(appearance.sizePoints),
                       weight: appearance.weight)
    }
}
