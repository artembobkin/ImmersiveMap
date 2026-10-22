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

    /// The collision bands: the countries, the regions and the cities beat
    /// the peaks beat the towns and every smaller place beat the water
    /// names beat the airports beat the route signs beat the other POIs
    /// beat the house numbers, whatever their ranks. A peak stands ahead
    /// of the settlements because it is what a mountain view is of: the
    /// Matterhorn's name over the hamlets on its slopes, not under them,
    /// while a city's name still wins the frame it is in.
    enum LabelBand {
        /// A country, a region, a city.
        case place
        /// A peak or a volcano.
        case peak
        /// A town, a village, a hamlet, a neighbourhood: every place under
        /// a city.
        case settlement
        case water
        /// An airport.
        case landmark
        case routeShield
        case poi
        case address

        var base: Int {
            switch self {
            case .place: return 0
            case .peak: return 10_000
            case .settlement: return 15_000
            case .water: return 20_000
            case .landmark: return 40_000
            case .routeShield: return 45_000
            case .poi: return 50_000
            case .address: return 70_000
            }
        }
    }

    /// Whether a place is a city or bigger: the places that keep their
    /// band ahead of the peaks (`LabelBand.place`).
    static func isMajorPlace(kind: String?, kindDetail: String?) -> Bool {
        switch kind {
        case "country", "region": return true
        case "locality": return kindDetail == "city"
        default: return false
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
        // The slot of the theme's labels the place is set in, read from
        // the plane's labels and, for the colours on the globe, from the
        // globe's.
        let slot: KeyPath<ProtomapsBasemapTheme.LabelStyles, ProtomapsBasemapTheme.LabelAppearance>
        // The name of a land goes away where the land no longer fits the
        // view (`LabelVisibility.countryMaximumZoom`, `regionMaximumZoom`).
        var maxCameraZoom = Float.infinity
        switch kind {
        case "country":
            slot = \.country
            maxCameraZoom = Float(theme.labelVisibility.countryMaximumZoom)
        case "region":
            slot = \.region
            maxCameraZoom = Float(theme.labelVisibility.regionMaximumZoom)
        case "locality":
            switch kindDetail {
            case "city":
                slot = \.city
            case "town":
                slot = \.town
            default:
                // A village, a hamlet, and the rest: in a city, its named
                // corners (a square, a quarter), which read as its
                // districts do, never in a city's deep black.
                slot = \.district
            }
        default: // macrohood, neighbourhood
            slot = \.district
        }
        var appearance = theme.labels[keyPath: slot]
        // A national capital is a city carrying the `capital` attribute.
        if kind == "locality", kindDetail == "city", isCapital(props) {
            appearance.sizePoints += 1.5
            appearance.weight = .bold
        }
        let rank = placeRank(kind: kind, props: props)
        return pointLabel(key: 70,
                          band: Self.isMajorPlace(kind: kind, kindDetail: kindDetail) ? .place : .settlement,
                          rank: rank,
                          appearance: appearance,
                          globeAppearance: theme.globeLabels?[keyPath: slot],
                          maxCameraZoom: maxCameraZoom)
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
                          globeAppearance: theme.globeLabels?.water,
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
    /// their own keys and collision bands (`LabelBand.peak`, `.landmark`).
    static func isLandmarkPoi(kind: String?) -> Bool {
        switch kind {
        case "peak", "volcano", "aerodrome":
            return true
        default:
            return false
        }
    }

    /// The band a POI collides in: the peaks ahead of the settlements, the
    /// airports behind the water names, the rest behind the route signs.
    static func poiBand(kind: String?) -> LabelBand {
        switch kind {
        case "peak", "volcano": return .peak
        case "aerodrome": return .landmark
        default: return .poi
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
        let icon = Self.poiIcon(kind: kind)
        let isIconless = icon == nil
        if isIconless {
            // A category the icon set does not know draws its name alone, in
            // the category colour: a stand-in dot says nothing the name does
            // not. A theme that wants such POIs gone (`poiRequiresIcon`) or
            // held back to a zoom (`poiIconlessMinimumZoom`) says so.
            guard theme.labelVisibility.poiRequiresIcon == false else {
                return hiddenStyle
            }
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
        // An icon-less POI is local detail: a plaque, an office, a ticket
        // window, read standing next to it and left to the look-at tile.
        return pointLabel(key: key,
                          band: Self.poiBand(kind: kind),
                          rank: minZoomRank(props: props),
                          appearance: appearance,
                          minCameraZoom: minCameraZoom,
                          icon: icon,
                          standsOnRoof: theme.features.labelsStandOnRoofs,
                          isLocal: isIconless && !isLandmark && visibility.localDetailInLookAtTileOnly)
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
                          minCameraZoom: Float(theme.labelVisibility.addressMinimumZoom),
                          standsOnRoof: theme.features.labelsStandOnRoofs,
                          isLocal: theme.labelVisibility.localDetailInLookAtTileOnly)
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
    /// its name alone or not at all (`poiRequiresIcon`).
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

    /// The plate of a POI's icon and the colour of its name, by the
    /// category its kind falls in (`ProtomapsBasemapTheme.PoiCategoryColors`),
    /// the POI appearance's own fill for a kind of no category.
    func poiCategoryColor(kind: String?) -> SIMD3<Float> {
        let plates = theme.labels.poiCategories
        switch kind {
        case "restaurant", "fast_food", "food_court", "ice_cream":
            return plates.food
        case "cafe", "bakery":
            return plates.coffee
        case "bar", "pub", "biergarten", "nightclub", "wine":
            return plates.bar
        case "supermarket", "mall", "convenience", "department_store", "marketplace",
             "gift", "hairdresser", "hardware", "laundry", "florist", "jewelry", "shoes", "clothes":
            return plates.shop
        case "hotel", "hostel", "guest_house", "motel":
            return plates.hotel
        case "hospital", "pharmacy", "chemist", "doctors", "dentist", "clinic":
            return plates.health
        case "school", "college", "university", "kindergarten", "library":
            return plates.education
        case "museum", "gallery", "attraction", "artwork", "theatre", "cinema",
             "arts_centre", "music_venue", "events_venue", "conference_centre":
            return plates.culture
        case "park", "garden", "national_park", "nature_reserve", "dog_park",
             "stadium", "pitch", "sports_centre", "swimming_pool", "golf_course", "playground", "picnic_site":
            return plates.leisure
        case "station", "aerodrome", "airfield", "heliport", "fuel", "charging_station",
             "car_rental", "ferry_terminal", "harbour", "halt", "tram_stop", "subway_entrance",
             "platform", "bus_stop", "bus_station", "stop", "taxi", "mobility_hub",
             "parking", "parking_entrance", "parking_space", "bicycle_parking",
             "motorcycle_parking", "kick-scooter_parking", "car_sharing", "bicycle_rental":
            return plates.transport
        case "bank", "post_office", "townhall", "police", "fire_station", "government",
             "atm", "bureau_de_change", "money_transfer", "courthouse", "civic_admin",
             "administrative", "community_centre", "embassy", "social_facility", "toilets":
            return plates.civic
        case "place_of_worship", "religious", "religious_administration", "monastery":
            return plates.worship
        default:
            return theme.labels.poi.fillColor
        }
    }

    /// `globeAppearance` is the slot of the globe's labels the label's
    /// colours on the globe come from, nil for a label never on the globe
    /// (a POI, an address) or a theme whose globe wears the plane's labels.
    func pointLabel(key: UInt8,
                    band: LabelBand,
                    rank: Int,
                    appearance: ProtomapsBasemapTheme.LabelAppearance,
                    globeAppearance: ProtomapsBasemapTheme.LabelAppearance? = nil,
                    minCameraZoom: Float = 0,
                    maxCameraZoom: Float = .infinity,
                    icon: PoiSpriteIcon? = nil,
                    placement: LabelPlacement = .screen,
                    standsOnRoof: Bool = false,
                    isLocal: Bool = false) -> FeatureStyle {
        FeatureStyle.pointLabel(key: key,
                                labelTextStyle(key: Int(key), appearance: appearance, globeAppearance: globeAppearance),
                                rank: rank,
                                collisionRank: Self.labelCollisionRank(band: band, rank: rank),
                                minCameraZoom: minCameraZoom,
                                maxCameraZoom: maxCameraZoom,
                                icon: icon,
                                placement: placement,
                                standsOnRoof: standsOnRoof,
                                isLocal: isLocal)
    }

    /// The text style of an appearance, with the colours of
    /// `globeAppearance` as what the label wears on the globe where one
    /// is given.
    func labelTextStyle(key: Int,
                        appearance: ProtomapsBasemapTheme.LabelAppearance,
                        globeAppearance: ProtomapsBasemapTheme.LabelAppearance? = nil) -> LabelTextStyle {
        LabelTextStyle(key: key,
                       fillColor: appearance.fillColor,
                       strokeColor: appearance.strokeColor,
                       haloEm: appearance.haloEm,
                       sizePoints: LabelTypeScale.clamped(appearance.sizePoints),
                       weight: appearance.weight,
                       uppercased: appearance.uppercased,
                       emboldenPoints: appearance.emboldenPoints,
                       letterSpacingEm: appearance.letterSpacingEm,
                       opacity: appearance.opacity,
                       sphereFillColor: globeAppearance?.fillColor,
                       sphereStrokeColor: globeAppearance?.strokeColor)
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
