// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

extension ProtomapsBasemapTheme {
    /// The route signs: which networks are signed and on what sign, how
    /// large the numbers are, how often a road repeats them, and from which
    /// tile zoom each road class carries them.
    ///
    /// A route is matched against `rules` in order, and the first rule whose
    /// network pattern matches decides its sign. The same order is the order
    /// the signs stand in on a road that carries several routes, so the
    /// rules list the national networks before the European one: a road
    /// signed `М-9` and `E22` reads `М-9` first. A route no rule matches
    /// (and a route of no network, a bare `ref`) takes `fallback`.
    public struct RouteShields: Equatable, Sendable {
        public struct Rule: Equatable, Sendable {
            /// The network pattern, compared without regard to case, one
            /// segment per colon. `*` stands for any one segment, and as
            /// the last segment for one or more: `US:*` matches `US:CA` and
            /// `US:NJ:CR`, `US:*:*` only the second.
            public var network: String
            /// The sign, nil for a network that is not signed at all.
            public var appearance: RouteShieldAppearance?

            public init(network: String, appearance: RouteShieldAppearance?) {
                self.network = network
                self.appearance = appearance
            }

            func matches(_ network: String) -> Bool {
                let pattern = self.network.lowercased().split(separator: ":", omittingEmptySubsequences: false)
                let segments = network.lowercased().split(separator: ":", omittingEmptySubsequences: false)
                for (index, part) in pattern.enumerated() {
                    guard index < segments.count else {
                        return false
                    }
                    if part == "*" {
                        if index == pattern.count - 1 {
                            return true
                        }
                        continue
                    }
                    if part != segments[index] {
                        return false
                    }
                }
                return segments.count == pattern.count
            }
        }

        public var rules: [Rule]
        /// The sign of a route no rule matches, nil to leave such routes
        /// unsigned.
        public var fallback: RouteShieldAppearance?
        /// The em size of the numbers in layout points.
        public var sizePoints: Float
        public var weight: LabelFontWeight
        /// The least distance between two copies of a road's signs, in
        /// layout points at the tile's zoom.
        public var spacingPoints: Float
        /// The most signs one road carries side by side.
        public var maximumCount: Int
        /// The tile zoom a road class first carries its signs at.
        public var minimumTileZoom: RoadClassValues<Int>

        public init(rules: [Rule] = RouteShields.defaultRules,
                    fallback: RouteShieldAppearance? = RouteShields.defaultFallback,
                    sizePoints: Float = 11,
                    weight: LabelFontWeight = .bold,
                    spacingPoints: Float = 220,
                    maximumCount: Int = 2,
                    minimumTileZoom: RoadClassValues<Int> = RouteShields.defaultMinimumTileZoom) {
            self.rules = rules
            self.fallback = fallback
            self.sizePoints = sizePoints
            self.weight = weight
            self.spacingPoints = spacingPoints
            self.maximumCount = maximumCount
            self.minimumTileZoom = minimumTileZoom
        }

        /// The signs of a road's routes: each route on the sign its network
        /// is given, in the rules' order (a route the fallback signs after
        /// every ruled one), the same number never twice, at most
        /// `maximumCount`.
        public func shields(for routes: [ImmersiveMapRouteFacts]) -> [RouteShield] {
            var ranked: [(order: Int, shield: RouteShield)] = []
            for route in routes where route.text.isEmpty == false {
                let order: Int
                let appearance: RouteShieldAppearance?
                if let index = rules.firstIndex(where: { $0.matches(route.network) }) {
                    order = index
                    appearance = rules[index].appearance
                } else {
                    order = rules.count
                    appearance = fallback
                }
                guard let appearance,
                      ranked.contains(where: { $0.shield.text == route.text }) == false else {
                    continue
                }
                ranked.append((order, RouteShield(text: route.text, appearance: appearance)))
            }
            // A stable sort: two routes of one rule keep the source's order.
            let ordered = ranked.enumerated().sorted { lhs, rhs in
                lhs.element.order != rhs.element.order
                    ? lhs.element.order < rhs.element.order
                    : lhs.offset < rhs.offset
            }
            return ordered.prefix(max(0, maximumCount)).map(\.element.shield)
        }

        var fingerprintComponents: [Float] {
            var out: [Float] = [sizePoints, Float(weight.rawValue), spacingPoints, Float(maximumCount)]
            out.append(contentsOf: minimumTileZoom.all.map(Float.init))
            func add(_ appearance: RouteShieldAppearance?) {
                guard let appearance else {
                    out.append(-1)
                    return
                }
                out.append(Float(appearance.shape.rawValue))
                for color in [appearance.fillColor, appearance.textColor, appearance.borderColor,
                              appearance.headerColor ?? SIMD3<Float>(repeating: -1)] {
                    out.append(contentsOf: [color.x, color.y, color.z])
                }
                out.append(contentsOf: [appearance.borderEm, appearance.cornerRadiusEm,
                                        appearance.paddingEm, appearance.headerFraction])
            }
            for rule in rules {
                out.append(contentsOf: rule.network.utf8.map(Float.init))
                add(rule.appearance)
            }
            add(fallback)
            return out
        }
    }
}

public extension ProtomapsBasemapTheme.RouteShields {
    /// A plain plate for a route of a network no rule names: white, with a
    /// grey edge and a dark number, a sign that says "route" without
    /// claiming any country's colours.
    static let defaultFallback: RouteShieldAppearance? = RouteShieldAppearance(
        fillColor: SIMD3<Float>(1, 1, 1),
        textColor: SIMD3<Float>(0.25, 0.25, 0.27),
        borderColor: SIMD3<Float>(0.58, 0.59, 0.61),
        borderEm: 0.08
    )

    /// The motorways and trunks carry their signs from the first road-path
    /// tile, z8. The lesser classes follow as the map gets room for them,
    /// and the service roads and paths carry none.
    static let defaultMinimumTileZoom = ProtomapsBasemapTheme.RoadClassValues<Int>(
        motorway: 8,
        trunk: 8,
        primary: 9,
        secondary: 11,
        tertiary: 12,
        minor: 13,
        service: 99,
        path: 99,
        other: 99
    )

    /// The signs as each country posts them on its roads: the colours of
    /// the plate and of the number, and the white or black edge the plate
    /// has. The national networks come first, so a road that is also a
    /// European route leads with its national number, and the European
    /// routes follow on their green plate. The Asian Highway numbers, the
    /// US truck, historic and auto-trail routes and the US county routes
    /// are not signed.
    static let defaultRules: [Rule] = {
        let white = SIMD3<Float>(1, 1, 1)
        let black = SIMD3<Float>(0.08, 0.08, 0.08)
        let red = SIMD3<Float>(0.827, 0.133, 0.145)
        let green = SIMD3<Float>(0.0, 0.502, 0.271)
        let blue = SIMD3<Float>(0.0, 0.345, 0.667)
        let yellow = SIMD3<Float>(1.0, 0.8, 0.0)
        let border: Float = 0.09

        let whiteOnRed = RouteShieldAppearance(fillColor: red, textColor: white, borderColor: white, borderEm: border)
        let whiteOnGreen = RouteShieldAppearance(fillColor: green, textColor: white, borderColor: white, borderEm: border)
        let whiteOnBlue = RouteShieldAppearance(fillColor: blue, textColor: white, borderColor: white, borderEm: border)
        let blackOnYellow = RouteShieldAppearance(fillColor: yellow, textColor: black, borderColor: black, borderEm: 0.07)

        return [
            // Russia: sign 6.14.1, a white number on red.
            Rule(network: "ru:national", appearance: whiteOnRed),
            // Germany: the Autobahn on blue, the Bundesstraße on yellow.
            Rule(network: "BAB", appearance: whiteOnBlue),
            Rule(network: "DE:national", appearance: blackOnYellow),
            // The United Kingdom's motorways, on their lighter blue.
            Rule(network: "UK:motorway",
                 appearance: RouteShieldAppearance(fillColor: SIMD3<Float>(0.0, 0.475, 0.757),
                                                   textColor: white, borderColor: white, borderEm: border)),
            // France: the autoroutes and routes nationales on red, the
            // départementales on yellow.
            Rule(network: "FR:A-road", appearance: whiteOnRed),
            Rule(network: "FR:N-road", appearance: whiteOnRed),
            Rule(network: "FR:*:D-road", appearance: blackOnYellow),
            // Italy: the autostrade on green, the strade statali on blue.
            Rule(network: "IT:A-road", appearance: whiteOnGreen),
            Rule(network: "IT", appearance: whiteOnBlue),
            // Spain: the autovías and autopistas on blue.
            Rule(network: "ES:A-road", appearance: whiteOnBlue),
            Rule(network: "ES:AP-highway", appearance: whiteOnBlue),
            Rule(network: "ES:R-highway", appearance: whiteOnBlue),
            // Poland: the motorways, expressways and national roads on
            // red, the voivodeship roads on yellow.
            Rule(network: "PL:motorway", appearance: whiteOnRed),
            Rule(network: "PL:expressway", appearance: whiteOnRed),
            Rule(network: "PL:national", appearance: whiteOnRed),
            Rule(network: "PL:regional", appearance: blackOnYellow),
            // Japan: the expressway numbers on green, the national routes
            // on blue.
            Rule(network: "JP:E", appearance: whiteOnGreen),
            Rule(network: "JP:national", appearance: whiteOnBlue),
            // The United States: the Interstate's blue shield under its red
            // crown, the US highway's white shield, and the state routes on
            // a white oval.
            Rule(network: "US:I",
                 appearance: RouteShieldAppearance(shape: .escutcheon,
                                                   fillColor: SIMD3<Float>(0.0, 0.247, 0.529),
                                                   textColor: white,
                                                   borderColor: white,
                                                   borderEm: border,
                                                   headerColor: SIMD3<Float>(0.686, 0.118, 0.176))),
            Rule(network: "US:US",
                 appearance: RouteShieldAppearance(shape: .escutcheon,
                                                   fillColor: white,
                                                   textColor: black,
                                                   borderColor: black,
                                                   borderEm: border)),
            Rule(network: "US:I:*", appearance: nil),
            Rule(network: "US:US:*", appearance: nil),
            Rule(network: "US:*:*", appearance: nil),
            Rule(network: "US:*",
                 appearance: RouteShieldAppearance(shape: .capsule,
                                                   fillColor: white,
                                                   textColor: black,
                                                   borderColor: black,
                                                   borderEm: border)),
            // The European routes, after every national network.
            Rule(network: "e-road", appearance: whiteOnGreen),
            Rule(network: "AsianHighway", appearance: nil),
            Rule(network: "AH", appearance: nil)
        ]
    }()
}
