// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The labels: every named point of `places`, `water` and `pois` and every
/// house number of `buildings` becomes a label on each tile that ships it.
/// The POIs and the house numbers wait for the camera zoom the theme's
/// `labelVisibility` gives them, and how the rest rank against each other
/// decides which of them the collisions keep. The road names are laid
/// along the roads themselves (`roadStyle`).
extension ProtomapsBasemapDefaultMapStyle {
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
    /// beat the other POIs beat the house numbers whatever their ranks.
    enum LabelBand {
        case place
        case water
        case landmark
        case poi
        case address

        var base: Int {
            switch self {
            case .place: return 0
            case .water: return 20_000
            case .landmark: return 40_000
            case .poi: return 50_000
            case .address: return 70_000
            }
        }
    }

    static func labelCollisionRank(band: LabelBand, rank: Int) -> Int {
        band.base + rank
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
    /// grows with the map from half a zoom in, and stays on the water at
    /// every deeper zoom, covering the same ground as the water it names.
    static func waterLabelSurfacePlacement(minimumZoom: Int) -> SurfaceLabelPlacement {
        let start = Double(max(minimumZoom, 0))
        return SurfaceLabelPlacement(referenceZoom: start + 0.5,
                                     minimumZoom: start,
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
    func poiLabelStyle(kind: String?, props: [String: MvtValue]) -> FeatureStyle {
        let visibility = theme.labelVisibility
        // The basemap ranks a POI by the zoom it belongs to: its deepest
        // tile (z15) ships the whole street, down to the cafés at 16, the
        // shops at 17 and the bus stops at 18, and the POI waits for that
        // camera zoom instead of crowding the ones ranked above it.
        var minCameraZoom: Float = 0
        if visibility.poiFollowsSourceMinimumZoom, let sourceMinimumZoom = parseIntValue(props["min_zoom"]) {
            minCameraZoom = Float(sourceMinimumZoom)
        }
        if let category = Self.poiCategory(kind: kind) {
            minCameraZoom = max(minCameraZoom, Float(visibility.poiCategoryMinimumZoom.zoom(for: category)))
        }
        if let name = props["name"]?.stringValue, name.count > visibility.poiLongNameCharacterCount {
            minCameraZoom = max(minCameraZoom, Float(visibility.poiLongNameMinimumZoom))
        }
        var icon = Self.poiIcon(kind: kind)
        if icon == nil {
            // A category the icon set does not know draws with the plain
            // marker, a small dot in the category colour, so the place
            // still shows as a place and not as bare text. A theme that wants such POIs gone (`poiRequiresIcon`)
            // or held back to a zoom (`poiIconlessMinimumZoom`) says so.
            guard theme.labelVisibility.poiRequiresIcon == false else {
                return hiddenStyle
            }
            icon = .marker
            minCameraZoom = max(minCameraZoom, Float(theme.labelVisibility.poiIconlessMinimumZoom))
        }
        // The global POI floor is an absolute visibility gate that may
        // exceed everything above (up to hiding POIs entirely).
        minCameraZoom = max(minCameraZoom, Float(theme.labelVisibility.poiMinimumZoom))

        let isLandmark = Self.isLandmarkPoi(kind: kind)
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

    /// A house number: the address points of the `buildings` layer, which
    /// the schema reads as a label carrying the number. Small grey text
    /// with no icon, below every other label in the collisions, so a
    /// number shows only where the street and its places leave room.
    func addressLabelStyle(facts: ImmersiveMapFeatureFacts) -> FeatureStyle {
        guard facts.label != nil else {
            return hiddenStyle
        }
        var appearance = theme.labels.poi
        appearance.sizePoints -= 2
        appearance.weight = .thin
        appearance.fillColor = SIMD3<Float>(0.45, 0.45, 0.47)
        return pointLabel(key: 76,
                          band: .address,
                          rank: 0,
                          appearance: appearance,
                          minCameraZoom: Float(theme.labelVisibility.addressMinimumZoom))
    }

    /// The POI categories that wait for a zoom of their own
    /// (`LabelVisibility.PoiCategoryZooms`), from the POI's `kind`, the raw
    /// OSM value. Nil for the rest, which follow the basemap's rank alone:
    /// the landmarks, museums and theatres, the parks, the stations, the
    /// hospitals, the places of worship, the food and drink, the hotels,
    /// the malls and department stores.
    static func poiCategory(kind: String?) -> PoiCategory? {
        switch kind {
        case "university", "college", "research_institute":
            return .campus
        case "mall", "department_store", "marketplace":
            return nil
        case "post_office", "post_box", "parcel_locker", "bank", "atm", "bureau_de_change",
             "money_transfer", "pharmacy", "chemist", "clinic", "doctors", "dentist",
             "school", "kindergarten", "childcare", "music_school", "language_school", "driving_school",
             "townhall", "civic_admin", "administrative", "government", "courthouse", "embassy",
             "police", "fire_station", "community_centre", "social_facility",
             "toilets", "fuel", "charging_station", "car_wash", "car_repair", "veterinary",
             "hairdresser", "laundry", "dry_cleaning", "copyshop":
            return .service
        case "bus_stop", "stop", "tram_stop", "platform", "subway_entrance", "halt", "taxi",
             "ticket_validator", "parking", "parking_entrance", "parking_space",
             "bicycle_parking", "motorcycle_parking", "kick-scooter_parking", "car_sharing",
             "bicycle_rental", "mobility_hub":
            return .transitDetail
        default:
            return poiIcon(kind: kind) == .shopping ? .shop : nil
        }
    }

    /// The sprite a POI draws beside its name, from its `kind`, the raw OSM
    /// value. Nil for a category with no symbol of its own, which draws
    /// with the plain marker or not at all (`poiRequiresIcon`).
    static func poiIcon(kind: String?) -> PoiSpriteIcon? {
        switch kind {
        case "restaurant", "fast_food", "food_court", "ice_cream":
            return .restaurant
        case "cafe", "bakery", "pastry", "coffee", "tea", "juice_bar", "internet_cafe":
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
        case "stadium", "sports_centre", "pitch", "fitness_centre", "sports", "dojo", "ice_rink",
             "swimming_pool", "playground", "golf_course":
            return .stadium
        case "hotel", "hostel", "guest_house", "motel":
            return .hotel
        case "supermarket", "mall", "convenience", "department_store", "marketplace",
             "grocery", "kiosk", "deli", "alcohol", "wine", "cheese", "seafood", "confectionery",
             "health_food", "greengrocer", "butcher", "retail", "clothes", "shoes", "bag",
             "fashion_accessories", "jewelry", "watches", "gift", "books", "stationery",
             "newsagent", "toys", "electronics", "mobile_phone", "hifi", "hardware", "doityourself",
             "furniture", "houseware", "florist", "cosmetics", "perfumery", "beauty", "optician",
             "pet", "bicycle", "car", "second_hand", "antiques", "art", "music", "musical_instrument",
             "photo", "fabric", "tobacco", "e-cigarette", "cannabis", "variety_store", "baby_goods":
            return .shopping
        case "fuel", "charging_station":
            return .gasStation
        case "pharmacy", "chemist":
            return .pharmacy
        case "viewpoint", "attraction", "peak", "volcano":
            return .viewpoint
        case "station", "halt", "tram_stop", "subway_entrance", "platform":
            return .train
        case "bus_stop", "bus_station", "stop", "taxi", "ferry_terminal", "mobility_hub":
            return .transit
        case "parking", "parking_entrance", "parking_space", "bicycle_parking",
             "motorcycle_parking", "kick-scooter_parking", "car_sharing", "bicycle_rental":
            return .parking
        case "bank", "atm", "bureau_de_change", "money_transfer":
            return .bank
        case "theatre", "cinema", "arts_centre", "music_venue", "events_venue", "conference_centre":
            return .theatre
        case "toilets":
            return .toilets
        case "townhall", "police", "fire_station", "post_office", "courthouse", "civic_admin",
             "administrative", "community_centre", "embassy", "social_facility":
            return .civic
        case "place_of_worship", "religious", "religious_administration", "monastery":
            return .worship
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
        case "museum", "gallery", "attraction", "artwork", "theatre", "cinema",
             "arts_centre", "music_venue", "events_venue", "conference_centre":
            return SIMD3<Float>(0.46, 0.30, 0.66)   // culture: violet
        case "park", "garden", "national_park", "nature_reserve", "dog_park",
             "stadium", "pitch", "sports_centre", "swimming_pool", "golf_course", "playground", "picnic_site":
            return SIMD3<Float>(0.22, 0.54, 0.30)   // leisure/nature: green
        case "station", "aerodrome", "airfield", "heliport", "fuel", "charging_station",
             "car_rental", "ferry_terminal", "harbour", "halt", "tram_stop", "subway_entrance",
             "platform", "bus_stop", "bus_station", "stop", "taxi", "mobility_hub",
             "parking", "parking_entrance", "parking_space", "bicycle_parking",
             "motorcycle_parking", "kick-scooter_parking", "car_sharing", "bicycle_rental":
            return SIMD3<Float>(0.32, 0.42, 0.55)   // transport: blue-gray
        case "bank", "post_office", "townhall", "police", "fire_station", "government",
             "atm", "bureau_de_change", "money_transfer", "courthouse", "civic_admin",
             "administrative", "community_centre", "embassy", "social_facility", "toilets":
            return SIMD3<Float>(0.40, 0.44, 0.52)   // offices/public services: gray-blue
        case "place_of_worship", "religious", "religious_administration", "monastery":
            return SIMD3<Float>(0.55, 0.45, 0.22)   // worship: muted gold
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

/// A POI category that waits for a zoom of its own, see
/// `ProtomapsBasemapTheme.LabelVisibility.PoiCategoryZooms`.
enum PoiCategory {
    case campus
    case shop
    case service
    case transitDetail
}

extension ProtomapsBasemapTheme.LabelVisibility.PoiCategoryZooms {
    func zoom(for category: PoiCategory) -> Int {
        switch category {
        case .campus: return campus
        case .shop: return shop
        case .service: return service
        case .transitDetail: return transitDetail
        }
    }
}
