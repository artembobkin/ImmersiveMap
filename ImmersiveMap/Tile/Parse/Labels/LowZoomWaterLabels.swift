// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The ocean and sea names the parser adds to the coarse zooms itself, with
/// their anchors and their spellings per language, and the projection that
/// puts an anchor into a tile. Data only: `LabelFeatureReader` decides which
/// of them a tile shows.
enum LowZoomWaterLabels {
    struct Label {
        /// Spellings keyed by language code, the keys `TileLabelDecisions.localizedName`
        /// walks.
        let names: [String: String]
        let latitude: Double
        let longitude: Double
        let sortKey: Int
        /// The `class` and `type` the label is styled as: `ocean` or `sea`.
        let styleClass: String

        var aliases: Set<String> {
            Set(names.values.filter { $0.isEmpty == false })
        }

        /// Whether any spelling of the name is already on the tile as a
        /// water label, so the tile's own label wins.
        func isDuplicate(of existingWaterText: Set<String>) -> Bool {
            aliases.isDisjoint(with: existingWaterText) == false
        }
    }

    /// The five oceans at every zoom up to 2, plus four seas at zoom 2.
    static func labels(for tile: Tile) -> [Label] {
        var labels: [Label] = [
            Label(names: [
                "en": "Pacific Ocean",
                "ru": "Тихий океан",
                "fr": "Océan Pacifique",
                "de": "Pazifischer Ozean",
                "es": "Océano Pacífico",
                "it": "Oceano Pacifico",
                "pt": "Oceano Pacífico",
                "tr": "Pasifik Okyanusu"
            ], latitude: 0.0, longitude: -150.0, sortKey: 20, styleClass: "ocean"),
            Label(names: [
                "en": "Atlantic Ocean",
                "ru": "Атлантический океан",
                "fr": "Océan Atlantique",
                "de": "Atlantischer Ozean",
                "es": "Océano Atlántico",
                "it": "Oceano Atlantico",
                "pt": "Oceano Atlântico",
                "tr": "Atlas Okyanusu"
            ], latitude: 8.0, longitude: -32.0, sortKey: 18, styleClass: "ocean"),
            Label(names: [
                "en": "Indian Ocean",
                "ru": "Индийский океан",
                "fr": "Océan Indien",
                "de": "Indischer Ozean",
                "es": "Océano Índico",
                "it": "Oceano Indiano",
                "pt": "Oceano Índico",
                "tr": "Hint Okyanusu"
            ], latitude: -18.0, longitude: 80.0, sortKey: 22, styleClass: "ocean"),
            Label(names: [
                "en": "Arctic Ocean",
                "ru": "Северный Ледовитый океан",
                "fr": "Océan Arctique",
                "de": "Arktischer Ozean",
                "es": "Océano Ártico",
                "it": "Mar Glaciale Artico",
                "pt": "Oceano Ártico",
                "tr": "Arktik Okyanusu"
            ], latitude: 76.0, longitude: 15.0, sortKey: 16, styleClass: "ocean"),
            Label(names: [
                "en": "Southern Ocean",
                "ru": "Южный океан",
                "fr": "Océan Austral",
                "de": "Südlicher Ozean",
                "es": "Océano Austral",
                "it": "Oceano Australe",
                "pt": "Oceano Antártico",
                "tr": "Güney Okyanusu"
            ], latitude: -56.0, longitude: 25.0, sortKey: 24, styleClass: "ocean")
        ]

        if tile.z == 2 {
            labels.append(Label(names: [
                "en": "Mediterranean Sea",
                "ru": "Средиземное море",
                "fr": "Mer Méditerranée",
                "de": "Mittelmeer",
                "es": "Mar Mediterráneo",
                "it": "Mar Mediterraneo",
                "pt": "Mar Mediterrâneo",
                "tr": "Akdeniz"
            ], latitude: 35.0, longitude: 18.0, sortKey: 30, styleClass: "sea"))
            labels.append(Label(names: [
                "en": "Caribbean Sea",
                "ru": "Карибское море",
                "fr": "Mer des Caraïbes",
                "de": "Karibisches Meer",
                "es": "Mar Caribe",
                "it": "Mar dei Caraibi",
                "pt": "Mar do Caribe",
                "tr": "Karayip Denizi"
            ], latitude: 15.0, longitude: -74.0, sortKey: 32, styleClass: "sea"))
            labels.append(Label(names: [
                "en": "Arabian Sea",
                "ru": "Аравийское море",
                "fr": "Mer d'Arabie",
                "de": "Arabisches Meer",
                "es": "Mar Arábigo",
                "it": "Mar Arabico",
                "pt": "Mar Arábico",
                "tr": "Umman Denizi"
            ], latitude: 15.0, longitude: 64.0, sortKey: 34, styleClass: "sea"))
            labels.append(Label(names: [
                "en": "Bering Sea",
                "ru": "Берингово море",
                "fr": "Mer de Béring",
                "de": "Beringmeer",
                "es": "Mar de Bering",
                "it": "Mare di Bering",
                "pt": "Mar de Bering",
                "tr": "Bering Denizi"
            ], latitude: 57.0, longitude: -178.0, sortKey: 36, styleClass: "sea"))
        }

        return labels
    }

    /// The tile-space anchor of a geographic position, nil when it falls
    /// outside the tile.
    static func tilePoint(forLatitude latitude: Double,
                          longitude: Double,
                          tile: Tile) -> SIMD2<Int16>? {
        let n = pow(2.0, Double(tile.z))
        guard n > 0 else { return nil }

        let wrappedLongitude = ((longitude + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0) - 180.0
        let x = (wrappedLongitude + 180.0) / 360.0 * n

        let clampedLatitude = min(max(latitude, -85.05112878), 85.05112878)
        let latitudeRadians = clampedLatitude * .pi / 180.0
        let y = (1.0 - log(tan(latitudeRadians) + 1.0 / cos(latitudeRadians)) / .pi) * 0.5 * n

        let localX = (x - Double(tile.x)) * 4096.0
        let localY = (y - Double(tile.y)) * 4096.0
        guard localX >= 0.0, localX <= 4096.0, localY >= 0.0, localY <= 4096.0 else {
            return nil
        }

        let roundedX = Int16(max(0, min(4096, Int(localX.rounded()))))
        let roundedY = Int16(max(0, min(4096, Int(localY.rounded()))))
        return SIMD2<Int16>(roundedX, roundedY)
    }
}
