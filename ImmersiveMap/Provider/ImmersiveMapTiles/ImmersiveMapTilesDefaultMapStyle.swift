// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Default style for the OpenMapTiles-schema first-party provider. Visually in
/// the spirit of `MapboxDefaultMapStyle`, but reading the OpenMapTiles layer and
/// field contract (`class`/`subclass`/`brunnel`/`admin_level`/`rank`/`capital`).
final class ImmersiveMapTilesDefaultMapStyle: ImmersiveMapStyle {
    private static let implementationRevision: UInt32 = 31

    private let fallbackKey: UInt8 = 0
    private let landuseMinimumZoom = 6
    private let massiveOverviewMaximumZoom = 2
    private let globalLandcoverMaximumZoom = 9
    private let poiSpriteResolver = PoiSpriteResolver()
    private let configuration: ImmersiveMapTilesDefaultMapStyleConfiguration
    private let settings: ImmersiveMapSettings.StyleSettings
    private let mapBaseColors: ImmersiveMapBaseColors
    private let fallbackStyle: FeatureStyle

    init(configuration: ImmersiveMapTilesDefaultMapStyleConfiguration = .immersiveMapTilesDefault,
         settings: ImmersiveMapSettings.StyleSettings = ImmersiveMapSettings.default.style) {
        self.configuration = configuration
        self.settings = settings
        self.mapBaseColors = ImmersiveMapBaseColors(settings: settings.baseColors)
        self.fallbackStyle = FeatureStyle(
            key: fallbackKey,
            color: settings.fallbackFeatureColor,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    var preparedTileStyleRevision: UInt32 {
        settings.preparedTileStyleRevision &+ configuration.cacheFingerprint &+ Self.implementationRevision
    }

    func getMapBaseColors() -> ImmersiveMapBaseColors {
        mapBaseColors
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let layer = data.layerName.lowercased()
        let props = data.properties
        let z = data.tile.z
        let cls = props["class"]?.stringValue.lowercased()
        let subclass = props["subclass"]?.stringValue.lowercased()

        switch layer {
        case "background":
            // Synthetic full-tile base quad the engine emits per tile. OpenMapTiles
            // has no land polygon, so this is what paints the land; without it the
            // base falls through to the red debug fallback.
            let color: SIMD4<Float>
            if z <= massiveOverviewMaximumZoom {
                color = configuration.globalLandcover.grass
            } else if z <= globalLandcoverMaximumZoom {
                color = configuration.globalLandcover.land
            } else {
                color = configuration.layers.land
            }
            return polygon(key: 1, color: color)
        case "water":
            let color = z <= globalLandcoverMaximumZoom
                ? configuration.globalLandcover.water
                : configuration.layers.water
            return polygon(key: 20, color: color)
        case "waterway":
            return waterwayStyle(cls: cls, props: props)
        case "landcover":
            return landcoverStyle(cls: cls, subclass: subclass, tileZoom: z)
        case "globallandcover":
            return globalLandcoverStyle(cls: cls, tileZoom: z)
        case "landuse":
            return landuseStyle(cls: cls, tileZoom: z)
        case "park":
            return parkLayerStyle(cls: cls, subclass: subclass)
        case "building":
            return buildingStyle(tileZoom: z)
        case "aeroway":
            return line(key: 28, color: configuration.layers.aeroway, width: 4)
        case "transportation":
            return transportationStyle(cls: cls, props: props, tileZoom: z)
        case "boundary":
            return boundaryStyle(props: props, tileZoom: z)
        case "transportation_name":
            return roadLabelStyle(cls: cls)
        case "place":
            return placeLabelStyle(props: props)
        case "water_name":
            return waterLabelStyle(props: props)
        case "poi":
            return poiLabelStyle(props: props, tileZoom: z)
        case "mountain_peak":
            return pointLabel(key: 74, appearance: configuration.labels.poi)
        case "aerodrome_label":
            return pointLabel(key: 75, appearance: configuration.labels.poi)
        case "housenumber":
            return pointLabel(key: 76, appearance: houseNumberAppearance())
        default:
            return fallbackStyle
        }
    }

    // MARK: - Polygons

    private func landcoverStyle(cls: String?, subclass: String?, tileZoom: Int) -> FeatureStyle {
        // The continuous ESA `globallandcover` overlay covers z<=9 (the tile service's
        // overlay-maxzoom). Use it there and suppress the sparser OSM `landcover`,
        // which generalises into tile-filling polygons clipped at tile edges (abrupt
        // per-tile colour jumps). OSM landcover takes over from z10 (street detail).
        //
        // Порядок отрисовки полигонов - по возрастанию key. Бежевый landuse
        // (residential/industrial) опущен на key 9, а вся зелень идёт выше (11-18),
        // иначе парк, лежащий внутри жилого/квартального полигона (leisure=park
        // приходит как landcover grass/park), перекрывался бы бежевым и выглядел
        // как земля. Зелень ниже воды (key 20) и дорог.
        guard tileZoom >= 10 else {
            return hiddenStyle
        }
        // Каждый цвет landcover - на своём key (иначе `styles[key]` first-wins
        // схлопывает весь landcover тайла в цвет первого полигона, давая швы на
        // границах тайлов). Все они выше бежевого landuse (key 9) и ниже воды (20).
        switch cls {
        case "wood", "forest":
            return polygon(key: 11, color: configuration.layers.wood)
        case "grass":
            // OSM tags countless small courtyards/verges as generic grass; at city
            // zooms suppress those (keep only real green-space subclasses) so they
            // don't tint the whole city.
            if tileZoom >= 13, isGenericGrassSubclass(subclass) {
                return hiddenStyle
            }
            return polygon(key: 12, color: configuration.layers.grass)
        case "farmland":
            return polygon(key: 13, color: configuration.layers.farmland)
        case "wetland":
            return polygon(key: 14, color: configuration.layers.wetland)
        case "ice":
            return polygon(key: 17, color: configuration.layers.ice)
        case "sand":
            return polygon(key: 18, color: configuration.layers.sand)
        case "rock":
            // Голая порода = цвет земли; отдельный полигон поверх базы не нужен.
            return hiddenStyle
        default:
            // Unknown landcover: blend into the land base rather than paint it green.
            return hiddenStyle
        }
    }

    /// True for generic "grass" that is just urban verge/courtyard clutter (as
    /// opposed to a real park/garden/recreation area worth keeping green).
    private func isGenericGrassSubclass(_ subclass: String?) -> Bool {
        switch subclass {
        case "park", "garden", "recreation_ground", "golf_course", "cemetery",
             "meadow", "grassland", "nature_reserve", "dog_park", "pitch", "playground":
            return false
        default:
            return true
        }
    }

    /// ESA WorldCover-derived low-zoom landcover (layer `globallandcover`, merged
    /// into low-zoom tiles by the tile service). The dedicated soft-biome palette
    /// compresses contrast between neighbouring classes while keeping broad forests,
    /// grasslands, crops, wetlands and deserts legible at globe scale. At z0...2 the
    /// vegetation classes collapse into one large mass, with forests only subtly
    /// darker, so source polygon spikes do not dominate the globe. Per-class hole-free
    /// polygons are drawn in a fixed paint order: base land -> biomes -> snow on top.
    /// Keys stay below `water` (20) so oceans/lakes cover landcover.
    private func globalLandcoverStyle(cls: String?, tileZoom: Int) -> FeatureStyle {
        let colors = configuration.globalLandcover
        let usesMassiveOverview = tileZoom <= massiveOverviewMaximumZoom
        let overviewVegetation = colors.grass
        let overviewForest = blend(overviewVegetation, toward: colors.forest, amount: 0.25)
        switch cls {
        case "land":
            return polygon(key: 2, color: usesMassiveOverview ? overviewVegetation : colors.land)
        case "barren":
            return polygon(key: 3, color: colors.barren)
        case "grass", "shrub", "moss":
            return polygon(key: 4, color: colors.grass)
        case "crop":
            return polygon(key: 5, color: usesMassiveOverview ? overviewVegetation : colors.crop)
        case "forest":
            return polygon(key: 6, color: usesMassiveOverview ? overviewForest : colors.forest)
        case "wetland", "mangroves":
            return polygon(key: 7, color: usesMassiveOverview ? overviewVegetation : colors.wetland)
        case "snow":
            return polygon(key: 8, color: colors.snow)
        default:
            // urban / water: leave to the background and water layers.
            return hiddenStyle
        }
    }

    private func blend(_ base: SIMD4<Float>,
                       toward target: SIMD4<Float>,
                       amount: Float) -> SIMD4<Float> {
        base + (target - base) * amount
    }

    private func landuseStyle(cls: String?, tileZoom: Int) -> FeatureStyle {
        guard tileZoom >= landuseMinimumZoom else {
            return hiddenStyle
        }
        switch cls {
        case "residential", "suburb", "neighbourhood", "quarter", "allotments":
            // Бежевые жилые/квартальные заливки - в самый низ (key 9), под зелень,
            // иначе они перекрывают парки (landcover) внутри жилых полигонов.
            return polygon(key: 9, color: configuration.layers.residential)
        case "industrial", "commercial", "retail", "railway", "quarry":
            return polygon(key: 9, color: configuration.layers.industrial)
        case "cemetery", "grass", "park", "recreation_ground", "garden":
            // Один зелёный цвет для всей городской зелени (совпадает с landcover
            // grass), чтобы не было двухтонности на стыке слоёв.
            return polygon(key: 15, color: configuration.layers.grass)
        default:
            // Unknown landuse: blend into the land base instead of the red fallback.
            return hiddenStyle
        }
    }

    // MARK: - Lines

    private func waterwayStyle(cls: String?, props: [String: VectorTile_Tile.Value]) -> FeatureStyle {
        // Подземные/коллекторные водотоки (brunnel=tunnel, напр. Неглинная под
        // Александровским садом) в реальности не видны - не показываем.
        if props["brunnel"]?.stringValue.lowercased() == "tunnel" {
            return hiddenStyle
        }
        let width: Double
        switch cls {
        case "river", "canal":
            width = 2.5
        case "stream":
            width = 1.4
        default:
            width = 1.0
        }
        return line(key: 22, color: configuration.layers.water, width: width)
    }

    private func transportationStyle(cls: String?,
                                     props: [String: VectorTile_Tile.Value],
                                     tileZoom: Int) -> FeatureStyle {
        let brunnel = props["brunnel"]?.stringValue.lowercased()
        let isTunnel = brunnel == "tunnel"
        let subclass = props["subclass"]?.stringValue.lowercased()
        let roads = configuration.layers.roads
        // Road widths grow with zoom: hairlines at country/regional zooms, full
        // width at street level. Base widths below are the z14+ (full) values.
        let s = roadWidthScale(tileZoom: tileZoom)

        switch cls {
        case "motorway":
            return roadStyle(fillKey: 56, color: roads.motorway, width: 16 * s, priority: 95, casing: true, tunnel: isTunnel)
        case "trunk":
            return roadStyle(fillKey: 54, color: roads.trunk, width: 14 * s, priority: 90, casing: true, tunnel: isTunnel)
        case "primary":
            return roadStyle(fillKey: 52, color: roads.primary, width: 12 * s, priority: 80, casing: true, tunnel: isTunnel)
        case "secondary":
            return roadStyle(fillKey: 50, color: roads.secondary, width: 10 * s, priority: 78, casing: true, tunnel: isTunnel)
        case "tertiary":
            return roadStyle(fillKey: 48, color: roads.tertiary, width: 8 * s, priority: 74, casing: true, tunnel: isTunnel)
        case "minor":
            return roadStyle(fillKey: 44, color: roads.minor, width: 7.6 * s, priority: 50, casing: tileZoom >= 13, tunnel: isTunnel)
        case "service":
            return roadStyle(fillKey: 42, color: roads.service, width: 5.6 * s, priority: 45, casing: tileZoom >= 14, tunnel: isTunnel)
        case "path", "track":
            // Аллеи и дорожки парков (footway/path/track). Показываем только на
            // уличном зуме и тонкой сплошной линией - без пунктира, который раньше
            // читался как мусор над водой/парками.
            guard tileZoom >= 14 else {
                return hiddenStyle
            }
            return roadStyle(fillKey: 40, color: roads.path, width: 3.2 * s, priority: 35, casing: false, tunnel: isTunnel)
        case "rail", "transit":
            return railStyle(subclass: subclass, tileZoom: tileZoom)
        case "ferry":
            return line(key: 41, color: configuration.layers.water, width: 4 * s, dashLength: 8, dashGap: 8)
        default:
            return roadStyle(fillKey: 43, color: roads.minor, width: 6.0 * s, priority: 40, casing: tileZoom >= 13, tunnel: isTunnel)
        }
    }

    private func roadStyle(fillKey: UInt8,
                           color: SIMD4<Float>,
                           width: Double,
                           priority: Int,
                           casing: Bool,
                           tunnel: Bool) -> FeatureStyle {
        let fillGeometry = tunnel
            ? makeDashedRoadGeometry(width: width, dashLength: width * 2.0, dashGap: width * 1.2)
            : makeRoadGeometry(width: width)

        var passes: [LineRenderPass] = []
        if casing, tunnel == false {
            passes.append(
                LineRenderPass(key: fillKey &+ 80,
                               color: roadCasingColor(from: color),
                               parseGeometryStyleData: makeRoadGeometry(width: width * 1.5),
                               includeRoadLabelPath: false,
                               roadPassRole: .casing)
            )
        }
        passes.append(
            LineRenderPass(key: fillKey,
                           color: color,
                           parseGeometryStyleData: fillGeometry,
                           includeRoadLabelPath: false,
                           roadPassRole: .fill)
        )

        return FeatureStyle(
            key: fillKey,
            color: color,
            parseGeometryStyleData: fillGeometry,
            lineRenderPasses: passes,
            roadClassPriority: priority
        )
    }

    private func buildingStyle(tileZoom: Int) -> FeatureStyle {
        guard tileZoom >= 13 else {
            return fallbackStyle
        }
        // 3D extruded buildings driven by OpenMapTiles render_height / render_min_height.
        return FeatureStyle(
            key: 30,
            color: configuration.features.buildingFillColor,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0),
            usesExtrusion: true,
            extrusionHeightScale: 8.0,
            extrusionAnchorZoom: 16
        )
    }

    private func railStyle(subclass: String?, tileZoom: Int) -> FeatureStyle {
        // Метро (railway=subway) идёт тоннелями под зданиями/парками и читается как
        // непонятная штриховая линия - не показываем. Наземные ж/д (rail, tram,
        // light_rail, monorail) оставляем пунктиром.
        if subclass == "subway" {
            return hiddenStyle
        }
        let s = roadWidthScale(tileZoom: tileZoom)
        return FeatureStyle(
            key: 46,
            color: configuration.layers.roads.rail,
            parseGeometryStyleData: makeDashedRoadGeometry(width: 4.0 * s, dashLength: 8, dashGap: 8),
            roadClassPriority: 30
        )
    }

    /// Multiplier applied to the boundary widths so admin borders read thin on the
    /// globe (low-zoom tiles are magnified) and reach full width at regional zoom.
    private func boundaryWidthScale(tileZoom: Int) -> Double {
        switch tileZoom {
        case ...3: return 0.35
        case 4: return 0.5
        case 5: return 0.7
        case 6: return 0.85
        default: return 1.0
        }
    }

    /// Multiplier applied to the (z14+) base road widths so roads are thin hairlines
    /// at country/regional zooms and reach full width at street level.
    private func roadWidthScale(tileZoom: Int) -> Double {
        switch tileZoom {
        case ...7: return 0.15
        case 8: return 0.22
        case 9: return 0.30
        case 10: return 0.40
        case 11: return 0.52
        case 12: return 0.68
        case 13: return 0.84
        default: return 1.0
        }
    }

    private func boundaryStyle(props: [String: VectorTile_Tile.Value], tileZoom: Int) -> FeatureStyle {
        let adminLevel = parseIntValue(props["admin_level"]) ?? 4
        guard adminLevel <= 4 else {
            return hiddenStyle
        }
        // Ширина линии печётся в тайловых координатах, поэтому на глобусе
        // (низкозумные тайлы сильно растянуты) фиксированная ширина выглядит
        // непропорционально жирной. Тоньшим границы на малых зумах и выходим на
        // полную толщину к региональному зуму - как roadWidthScale для дорог, но
        // с более высоким полом: границы должны оставаться заметнее дорог.
        let scale = boundaryWidthScale(tileZoom: tileZoom)
        let width: Double = (adminLevel <= 2 ? 7.8 : 3.4) * scale
        let key: UInt8 = adminLevel <= 2 ? 102 : 100
        return FeatureStyle(
            key: key,
            color: configuration.layers.boundary,
            lowZoomFadeMask: 1.0,
            parseGeometryStyleData: makeDashedRoadGeometry(width: width, dashLength: 8, dashGap: 6),
            // Границы рисуем только линиями. Некоторые фичи (индейские
            // резервации) приходят полигонами - их площадь заливать нельзя,
            // иначе получаются сплошные фиолетовые пятна.
            suppressPolygonFill: true
        )
    }

    // MARK: - Labels

    private func placeLabelStyle(props: [String: VectorTile_Tile.Value]) -> FeatureStyle {
        let cls = props["class"]?.stringValue.lowercased()
        var appearance: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance
        switch cls {
        case "continent", "country":
            appearance = configuration.labels.country
        case "state", "province":
            var a = configuration.labels.country
            a.sizePx -= 4
            appearance = a
        case "city":
            appearance = configuration.labels.city
        case "town":
            appearance = configuration.labels.town
        default: // village, hamlet, suburb, quarter, neighbourhood, ...
            var a = configuration.labels.town
            a.sizePx -= 3
            a.weight = .thin
            appearance = a
        }
        if isCapital(props) {
            appearance.sizePx += 3
            appearance.weight = .bold
        }
        return pointLabel(key: 70, appearance: appearance)
    }

    private func waterLabelStyle(props: [String: VectorTile_Tile.Value]) -> FeatureStyle {
        var appearance = configuration.labels.water
        switch props["class"]?.stringValue.lowercased() {
        case "ocean":
            appearance.sizePx += 6
        case "sea":
            appearance.sizePx += 3
        default:
            break
        }
        return pointLabel(key: 73, appearance: appearance)
    }

    // POI: и кружок-иконка, и подпись красятся в цвет категории заведения.
    // Цвет идёт через LabelTextStyle.fillColor - его использует и фон иконки
    // (PoiIconStyleUniform.backgroundColor), и заливка текста; глиф иконки белый.
    // Ключ у всех POI один (72): runs группируются по полной идентичности стиля
    // (вес + цвета), поэтому разные категории раскладываются в отдельные draw-runs.
    private func poiLabelStyle(props: [String: VectorTile_Tile.Value], tileZoom: Int) -> FeatureStyle {
        // Появление POI выводится из бюджета и приоритетов, без абсолютных
        // зум-рамп: лейбл виден, когда его эффективный ранг укладывается в
        // бюджет клетки сетки, а бюджет растёт вчетверо за каждый зум
        // оверзума - ровно как экранная площадь тайла. Решение сворачивается
        // в статичный порог minCameraZoom = tile.z + log4(effRank / бюджет),
        // который рантайм и коллизии применяют по зуму камеры. Классы задают
        // не зумы, а смещение приоритета в единицах ранга, поэтому подход не
        // зависит от maxzoom источника: смена источника сдвигает пороги
        // автоматически через tile.z.
        let cls = props["class"]?.stringValue.lowercased()
        let subclass = props["subclass"]?.stringValue.lowercased()
        let rank = Double(parseIntValue(props["rank"]) ?? Self.poiDefaultRank)
        let effectiveRank = max(Self.poiNativeCellBudget,
                                rank + Self.poiClassRankBias(cls: cls, subclass: subclass))
        var minCameraZoom = Float(tileZoom)
            + Float(log2(effectiveRank / Self.poiNativeCellBudget) / 2.0)
        let isIconless = poiSpriteResolver.resolve(attributes: props, layerName: "poi") == nil
        if isIconless {
            minCameraZoom = max(minCameraZoom, Float(configuration.labelVisibility.poiIconlessMinimumZoom))
        }
        minCameraZoom = min(minCameraZoom, Float(tileZoom) + Self.poiMaximumOverzoomAppearanceDelay)

        var appearance = configuration.labels.poi
        appearance.fillColor = poiCategoryColor(cls: cls, subclass: subclass)
        return pointLabel(key: 72, appearance: appearance, minCameraZoom: minCameraZoom)
    }

    /// Бюджет клетки сетки ранга на РОДНОМ зуме тайла: rank <= бюджета виден
    /// сразу с появлением тайла, каждый зум оверзума учетверяет бюджет.
    private static let poiNativeCellBudget = 1.0

    /// Ранг для фич без атрибута rank: середина хвоста.
    private static let poiDefaultRank = 15

    /// Потолок раскрытия: нейтральный хвост капа (rank 64) исчерпывается
    /// ровно к tile.z + 3, смещённая в плюс инфраструктура доезжает клампом
    /// к tile.z + 3.5. Глубже доставать из тайла уже нечего.
    private static let poiMaximumOverzoomAppearanceDelay: Float = 3.5

    /// Смещения приоритета классов в единицах ранга (зум-агностичны). Якоря
    /// уводятся в минус и видны с рождения тайла, городская ткань чуть раньше
    /// нейтральной коммерции, декоративная зелень чуть позже, уличная
    /// инфраструктура на ~два зума позже нейтральных.
    private static let poiMajorClasses: Set<String> = [
        "hospital", "railway", "aerodrome", "university", "college", "stadium",
        "museum", "zoo", "attraction", "harbor", "monument", "castle"
    ]
    private static let poiCommunityClasses: Set<String> = [
        "school", "theatre", "cinema", "lodging", "town_hall", "townhall",
        "library", "police", "fire_station", "pharmacy", "grocery", "park",
        "place_of_worship", "post", "bank", "campsite"
    ]
    private static let poiLateClasses: Set<String> = [
        "garden", "playground", "swimming_pool", "kindergarten", "sport"
    ]
    private static let poiInfrastructureClasses: Set<String> = [
        "bus", "bicycle_rental", "bicycle_rent", "parking", "fuel",
        "charging_station", "car", "car_rental", "atm"
    ]

    private static func poiClassRankBias(cls: String?, subclass: String?) -> Double {
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

    private func poiCategoryColor(cls: String?, subclass: String?) -> SIMD3<Float> {
        switch cls ?? subclass {
        case "restaurant", "fast_food", "food_court", "ice_cream":
            return SIMD3<Float>(0.85, 0.40, 0.12)   // еда - оранжевый
        case "cafe", "bakery":
            return SIMD3<Float>(0.58, 0.37, 0.18)   // кофе/выпечка - коричневый
        case "bar", "pub", "beer", "alcohol_shop", "nightclub", "wine":
            return SIMD3<Float>(0.62, 0.16, 0.34)   // бар - винный
        case "shop", "grocery", "supermarket", "mall", "clothing_store", "convenience",
             "gift", "hairdresser", "hardware", "laundry", "car", "florist", "jewelry", "shoe":
            return SIMD3<Float>(0.16, 0.44, 0.78)   // магазины - синий
        case "lodging":
            return SIMD3<Float>(0.66, 0.26, 0.60)   // отели - пурпурный
        case "hospital", "pharmacy", "doctors", "dentist", "clinic":
            return SIMD3<Float>(0.82, 0.22, 0.26)   // здоровье - красный
        case "school", "college", "university", "kindergarten", "library":
            return SIMD3<Float>(0.22, 0.46, 0.52)   // образование - бирюзовый
        case "museum", "art_gallery", "gallery", "attraction", "artwork", "theatre", "music", "cinema":
            return SIMD3<Float>(0.46, 0.30, 0.66)   // культура - фиолетовый
        case "park", "garden", "stadium", "pitch", "sport", "swimming", "golf", "playground", "picnic_site":
            return SIMD3<Float>(0.22, 0.54, 0.30)   // отдых/природа - зелёный
        case "bus", "railway", "airport", "aerialway", "fuel", "car_rental", "parking", "harbor", "ferry_terminal":
            return SIMD3<Float>(0.32, 0.42, 0.55)   // транспорт - сине-серый
        case "bank", "post", "office", "town_hall", "police", "fire_station", "government", "atm":
            return SIMD3<Float>(0.40, 0.44, 0.52)   // офисы/госуслуги - серо-синий
        default:
            return configuration.labels.poi.fillColor  // прочее - тёмный по умолчанию
        }
    }

    private func roadLabelStyle(cls: String?) -> FeatureStyle {
        FeatureStyle(
            key: 90,
            color: SIMD4<Float>(0, 0, 0, 0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 1),
            includeRoadLabelPath: true,
            roadClassPriority: roadLabelPriority(cls: cls),
            roadLabelTextStyle: labelTextStyle(key: 90, appearance: configuration.labels.road)
        )
    }

    private func houseNumberAppearance() -> ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance {
        var appearance = configuration.labels.poi
        appearance.sizePx = 12
        appearance.fillColor = SIMD3<Float>(0.55, 0.53, 0.50)
        return appearance
    }

    // MARK: - Builders

    /// Transparent no-op fill for known-but-unstyled area features (keeps them off
    /// the red debug fallback while still consuming the feature).
    private var hiddenStyle: FeatureStyle {
        FeatureStyle(
            key: fallbackKey,
            color: SIMD4<Float>(0, 0, 0, 0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    /// The OpenMapTiles `park` layer. `national_park`/`nature_reserve` are real green
    /// space; `protected_area` is a broad heritage/administrative designation that
    /// often blankets whole city centres (e.g. Moscow's historic core) - painting it
    /// green makes the entire city read as a park, so it is not drawn as green.
    private func parkLayerStyle(cls: String?, subclass: String?) -> FeatureStyle {
        // Слой park - зелёные зоны. Красим зелёным явные парки/сады/заповедники
        // (класс может быть кириллическим: национальный_парк, природно-исторический_парк,
        // ...). Крупные охранные зоны без паркового признака (protected_area,
        // "особо охраняемая ...", памятник природы) не показываем, чтобы не
        // заливать карту зелёным.
        let kind = "\(cls ?? "") \(subclass ?? "")"
        let greenKeywords = ["park", "парк", "garden", "сад", "reserve", "заповедник", "nature"]
        if greenKeywords.contains(where: { kind.contains($0) }) {
            return polygon(key: 16, color: configuration.layers.grass)
        }
        return hiddenStyle
    }

    private func polygon(key: UInt8, color: SIMD4<Float>) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: color,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    private func line(key: UInt8,
                      color: SIMD4<Float>,
                      width: Double,
                      dashLength: Double = 0,
                      dashGap: Double = 0) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: color,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: width,
                                                                         lineCapRound: true,
                                                                         lineJoinRound: true,
                                                                         dashLength: dashLength,
                                                                         dashGap: dashGap)
        )
    }

    private func pointLabel(key: UInt8,
                            appearance: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance,
                            minCameraZoom: Float = 0) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: SIMD4<Float>(0, 0, 0, 0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0),
            labelTextStyle: labelTextStyle(key: Int(key), appearance: appearance),
            labelMinCameraZoom: minCameraZoom
        )
    }

    /// Road border = the fill colour darkened and made fully opaque - a border of
    /// the same hue but darker, never see-through, drawn under the lighter fill.
    private func roadCasingColor(from fill: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(max(fill.x - 0.20, 0.0),
                     max(fill.y - 0.20, 0.0),
                     max(fill.z - 0.20, 0.0),
                     1.0)
    }

    private func makeRoadGeometry(width: Double) -> TileMvtParser.ParseGeometryStyleData {
        TileMvtParser.ParseGeometryStyleData(lineWidth: width, lineCapRound: true, lineJoinRound: true)
    }

    private func makeDashedRoadGeometry(width: Double,
                                        dashLength: Double,
                                        dashGap: Double) -> TileMvtParser.ParseGeometryStyleData {
        TileMvtParser.ParseGeometryStyleData(lineWidth: width,
                                             lineCapRound: true,
                                             lineJoinRound: false,
                                             dashLength: dashLength,
                                             dashGap: dashGap)
    }

    private func labelTextStyle(key: Int,
                                appearance: ImmersiveMapTilesDefaultMapStyleConfiguration.LabelAppearance) -> LabelTextStyle {
        LabelTextStyle(key: key,
                       fillColor: appearance.fillColor,
                       strokeColor: appearance.strokeColor,
                       strokeWidthPx: appearance.strokeWidthPx,
                       sizePx: appearance.sizePx,
                       weight: appearance.weight)
    }

    private func roadLabelPriority(cls: String?) -> Int {
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

    // MARK: - Property helpers

    private func isCapital(_ props: [String: VectorTile_Tile.Value]) -> Bool {
        if let capital = parseIntValue(props["capital"]), capital > 0 {
            return true
        }
        return false
    }

    private func parseIntValue(_ value: VectorTile_Tile.Value?) -> Int? {
        guard let value else {
            return nil
        }
        if value.hasIntValue {
            return Int(value.intValue)
        }
        if value.hasUintValue {
            return Int(value.uintValue)
        }
        if value.hasSintValue {
            return Int(value.sintValue)
        }
        if value.hasDoubleValue {
            return Int(value.doubleValue)
        }
        if value.hasFloatValue {
            return Int(value.floatValue)
        }
        if value.hasStringValue {
            return Int(value.stringValue.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
