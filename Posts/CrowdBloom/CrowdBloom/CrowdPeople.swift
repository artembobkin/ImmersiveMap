// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// The crowd the post flies into: fifty people over half a kilometre of
/// Barcelona's Eixample, plus a dozen scattered across the rest of the planet.
///
/// The layout is the whole subject of the video, so it is built rather than
/// sprinkled. Avatar markers keep a fixed size in drawable pixels while the
/// ground under them scales with zoom, which is what makes the same crowd read
/// as one flower cluster from orbit, as a handful of flowers over the
/// neighborhood, and as fifty separate portraits from the street. Where those
/// thresholds fall is a matter of metres between neighbors:
///
/// - a flower forms when anchors come within 0.35 marker widths of each other
///   (`AvatarCollisionMath.groupingRadiusScale`) and the pile reaches
///   `AvatarSettings.groupingThreshold` members;
/// - it holds together while its anchors stay inside 2.5 marker widths
///   (`flowerCompactnessLimitScale`), and splits into several flowers past that;
/// - it shows at most `maxFlowerPetals` (7) portraits and hides the rest, so a
///   knot of eight has something to give back on the way in.
///
/// With the post's marker size (`CrowdScale`, ~10.5% of the frame height) the
/// grouping radius is about 32 m of ground at zoom 15 and 168 m at zoom 12.6.
/// The crowd is therefore laid out as five tight knots of six to eight people
/// inside a 22 m radius (a terrace, a queue, a doorway) among fifteen
/// individuals a block apart: at zoom 15 the knots are five flowers while the
/// singles stand alone, and by zoom 12.6 the grouping radius is wider than the
/// block and the entire crowd is one flower. Fifty people over 580 by 650 m,
/// with a median 9.2 m between neighbours.
///
/// The grid is Cerdà's. Every position is placed on the Eixample's own axes
/// rather than on north and east, so the people stand along the streets instead
/// of cutting across the blocks.
enum CrowdPeople {
    /// Passeig de Gràcia at Carrer de Provença, next to Casa Milà.
    static let eixample = GeoCoordinate(latitude: 41.3954, longitude: 2.1619)

    /// The bearing that puts the Eixample grid square in frame.
    ///
    /// Passeig de Gràcia runs 42.4 degrees west of north (measured off its own
    /// endpoints, Plaça de Catalunya to Gràcia), and the cross streets run at a
    /// right angle to it. `CrowdStoryboard` holds this bearing from the first
    /// city shot to the last, so the blocks stay parallel to the frame edges
    /// and the only thing the eye has to follow is the crowd.
    static let gridBearing: Float = 0.740

    /// Side of a Cerdà block, chamfered corner to chamfered corner.
    private static let blockMeters = 133.0

    /// Grid axes in metres east and north: the avenue (uphill towards Gràcia)
    /// and the cross streets at a right angle to it.
    private static let avenueAxis = (east: -0.6743, north: 0.7385)
    private static let crossAxis = (east: 0.7385, north: 0.6743)

    /// Nodes of the grid that hold a knot, in (avenue, cross) block steps from
    /// the centre, with the number of people standing there.
    private static let knots: [(avenue: Double, cross: Double, count: Int)] = [
        (0, 0, 8),
        (-1, 1, 7),
        (1, -1, 7),
        (1, 1.5, 7),
        (-1.5, -1, 6),
    ]

    /// Nodes that hold a single person, in the same units.
    private static let singles: [(avenue: Double, cross: Double)] = [
        (-2, 0), (-2, 1.5), (-1, -2), (-1, 0), (0, -1.5),
        (0, 1), (0, 2), (1, 0), (1.5, 1), (2, -0.5),
        (2, 1), (-0.5, 2), (2, 2), (-2, -1.5), (0.5, -2),
    ]

    /// The people who are somewhere else entirely. They exist for the two
    /// globe shots that open and close the post: markers are anchored to the
    /// sphere like anything else on it, and the ones on the far side are cut by
    /// the horizon rather than drawn through the planet.
    private static let world: [(name: String, latitude: Double, longitude: Double)] = [
        ("Nils Åberg", 59.3293, 18.0686),        // Stockholm
        ("Marta Kubiak", 52.2297, 21.0122),      // Warsaw
        ("Rania Haddad", 30.0444, 31.2357),      // Cairo
        ("Deniz Aydın", 41.0082, 28.9784),       // Istanbul
        ("Iris Bakker", 52.3676, 4.9041),        // Amsterdam
        ("Sofia Ferreira", 38.7223, -9.1393),    // Lisbon
        ("Tomás Bravo", -34.6037, -58.3816),     // Buenos Aires
        ("Ana Melo", -23.5505, -46.6333),        // São Paulo
        ("June Park", 37.5665, 126.9780),        // Seoul
        ("Kaito Mori", 35.6762, 139.6503),       // Tokyo
        ("Nadia Rahman", 19.0760, 72.8777),      // Mumbai
        ("Ella Novak", -33.8688, 151.2093),      // Sydney
    ]

    private static let names = [
        "Júlia Roca", "Marc Ferrer", "Laia Puig", "Pau Serra", "Nuria Vidal",
        "Oriol Camps", "Aina Bosch", "Guillem Sol", "Carla Mas", "Roger Prat",
        "Berta Font", "Arnau Riera", "Mireia Gil", "Pol Duran", "Clara Bru",
        "Xavi Lloret", "Ona Ripoll", "Ivan Sala", "Emma Casals", "Sergi Marti",
        "Alba Colom", "Nil Torres", "Rita Vives", "Bruno Costa", "Lena Ortiz",
        "Hugo Salas", "Vera Pons", "Adria Nogue", "Sara Ibanez", "Max Aguilar",
        "Irene Blanc", "Dani Reyes", "Paula Cid", "Toni Miralles", "Noa Estev",
        "Lluis Gasol", "Maria Quer", "Eric Batlle", "Ines Farre", "Jan Coll",
        "Sonia Peris", "Gerard Lima", "Blanca Arxe", "Nico Terra", "Alma Vega",
        "Ruben Solé", "Teresa Miró", "Enric Dalmau", "Lucia Ferran", "Joel Rams",
    ]

    /// The one person the storyboard treats as "you": a selected marker pulses
    /// on a 0.9 s cycle for as long as it stays selected
    /// (`AvatarSelectionAnimationMath`). The pulse is a function of the render
    /// clock, which the offline export scripts frame by frame, so it is the one
    /// piece of avatar motion that survives into the video. It costs the export
    /// a full-length pre-roll: the pre-roll waits for avatar animations to go
    /// quiet before the first captured frame, and this one never does, so it
    /// runs to its timeout once per render.
    static let selectedID: UInt64 = 1

    static func makeMarkers() -> [AvatarMarker] {
        var random = SeededRandom(seed: 0x5EED_BA5C_E10A_2024)
        var markers: [AvatarMarker] = []
        var nextID: UInt64 = 1

        func add(name: String, coordinate: GeoCoordinate) {
            let id = nextID
            nextID += 1
            markers.append(AvatarMarker(id: id,
                                        coordinate: coordinate,
                                        image: CrowdPortraits.portrait(name: name,
                                                                       paletteIndex: Int(id)),
                                        batteryBadge: batteryBadge(for: id),
                                        speedBadge: speedBadge(for: id),
                                        isSelected: id == selectedID))
        }

        // The knots first, so "you" (id 1) lands in the middle of the densest
        // one: the flower it belongs to is the one the camera flies into.
        for knot in knots {
            let node = gridPoint(avenue: knot.avenue, cross: knot.cross)
            for _ in 0..<knot.count {
                // Polar jitter with a square-rooted radius: a uniform radius
                // piles everyone on the centre and leaves the ring empty.
                let angle = random.unit() * 2 * .pi
                let radius = 22.0 * random.unit().squareRoot()
                add(name: names[markers.count % names.count],
                    coordinate: offset(node,
                                       east: cos(angle) * radius,
                                       north: sin(angle) * radius))
            }
        }

        // Then the individuals, each a short walk off its intersection so the
        // grid does not read as a lattice of dots.
        for single in singles {
            let node = gridPoint(avenue: single.avenue, cross: single.cross)
            add(name: names[markers.count % names.count],
                coordinate: offset(node,
                                   east: random.range(-38, 38),
                                   north: random.range(-38, 38)))
        }

        for person in world {
            add(name: person.name,
                coordinate: GeoCoordinate(latitude: person.latitude, longitude: person.longitude))
        }

        return markers
    }

    /// A node of the Eixample grid, `avenue` blocks up the avenue and `cross`
    /// blocks along the cross streets from `eixample`.
    private static func gridPoint(avenue: Double, cross: Double) -> GeoCoordinate {
        offset(eixample,
               east: (avenue * avenueAxis.east + cross * crossAxis.east) * blockMeters,
               north: (avenue * avenueAxis.north + cross * crossAxis.north) * blockMeters)
    }

    private static func offset(_ base: GeoCoordinate, east: Double, north: Double) -> GeoCoordinate {
        let metresPerDegreeLatitude = 111_320.0
        let latitude = base.latitude + north / metresPerDegreeLatitude
        let longitude = base.longitude
            + east / (metresPerDegreeLatitude * cos(base.latitude * .pi / 180))
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    /// Badges on a third of the crowd and speeds on a fifth of it. Every marker
    /// carrying both would turn the street shot into a dashboard, and the point
    /// is that the badges are per-marker rather than a global toggle. They fade
    /// out by themselves as a marker is compressed into a petal
    /// (`AvatarCollisionMath.badgeContentAlpha`), so the wide shots stay clean
    /// without anything being switched off.
    private static func batteryBadge(for id: UInt64) -> AvatarBatteryBadge? {
        guard id % 3 == 0 else {
            return nil
        }
        return AvatarBatteryBadge(levelPct: Int(17 + (id &* 37) % 80))
    }

    private static func speedBadge(for id: UInt64) -> AvatarSpeedBadge? {
        guard id % 5 == 2 else {
            return nil
        }
        return AvatarSpeedBadge(kilometersPerHour: Int(4 + (id &* 11) % 26))
    }
}

/// A small linear congruential generator, so the crowd is the same crowd on
/// every launch and in every take. `Double.random` is seeded from the system
/// and would reshuffle the layout between the preview and the render.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    /// Uniform in `0..<1`.
    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + (upper - lower) * unit()
    }
}
