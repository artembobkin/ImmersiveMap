// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// A carriageway area (`subclass=carriageway_area`, a polygon in
/// `transportation`) is the surface of a stretch of street computed from the
/// road graph, the same thing a junction area is for a junction. It draws as
/// fill in the automobile tier (kerbless, like the whole tier), clips the
/// ribbons of the streets it
/// covers, and (being `origin=graph`) cuts their synthesized paint, so the
/// paint the source measured can ship as its own lines instead. A surface
/// owns only roads of its own structure and layer: a bridge deck polygon
/// leaves the street under it alone.
final class RoadCarriagewaySurfaceTests: XCTestCase {
    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
    }

    private let tile = Tile(x: 39615, y: 20486, z: 16)

    private func parse(_ features: [VectorTileFixture.Feature]) throws -> TileMvtParser.ParsedTile {
        try makeParser().parse(tile: tile,
                               mvtData: VectorTileFixture.layerTile(layerName: "transportation",
                                                                    features: features))
    }

    private func street(_ points: [(Int32, Int32)], id: UInt64 = 2,
                        extra: [String: String] = [:]) -> VectorTileFixture.Feature {
        var properties = ["class": "primary", "lanes": "4", "name": "Tverskaya Street"]
        for (key, value) in extra { properties[key] = value }
        return .init(id: id, geometry: .line(points: points), properties: properties)
    }

    private func surface(_ ring: [(Int32, Int32)], id: UInt64 = 1,
                         extra: [String: String] = [:]) -> VectorTileFixture.Feature {
        var properties = ["class": "primary", "subclass": "carriageway_area", "origin": "graph"]
        for (key, value) in extra { properties[key] = value }
        return .init(id: id, geometry: .polygon(ring: ring), properties: properties)
    }

    /// Deliberately OFF the tile centre: the old ring (y 1800-2300) mirrored
    /// onto itself, so a reintroduced mirror-clip would have passed every
    /// count-only assertion in this file.
    private let coveringRing: [(Int32, Int32)] = [(1800, 800), (2600, 800), (2600, 1300), (1800, 1300)]

    func testACarriagewayAreaStylesLikeAJunctionArea() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        func value(_ s: String) -> MvtValue { .string(s) }
        let area = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: ["class": value("primary"),
                                                                          "subclass": value("carriageway_area"),
                                                                          "origin": value("graph")],
                                                             tile: tile))
        XCTAssertTrue(area.isRoadSurfaceArea, "A carriageway area is a road surface")
        XCTAssertTrue(area.surfaceAreaCutsPaint,
                      "A graph-built surface carries the measured paint itself, so the synthesized paint ends at its edge")
        let primary = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.layers.roads.primary
        XCTAssertEqual(area.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }?.color, primary,
                       "The surface is exactly the class colour")
        XCTAssertNil(area.resolvedLineRenderPasses.first { $0.roadPassRole == .casing },
                     "and wears no kerb: the automobile tier is kerbless")
        XCTAssertEqual(area.roadClassPriority, 80, "sorted among the primaries")
    }

    func testACoveredRibbonIsClippedAwayUnderItsOwnClassSurface() throws {
        // The street lies entirely inside the surface, so the clipped ribbon
        // contributes nothing: the tile draws exactly what the surface alone
        // draws.
        let covered = try parse([surface(coveringRing), street([(1900, 1050), (2500, 1050)])])
        let surfaceOnly = try parse([surface(coveringRing)])
        let automobile = covered.drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(automobile.fill.drawing.indices.count, 0, "The surface fill draws")
        XCTAssertEqual(automobile.fill.drawing.indices.count,
                       surfaceOnly.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                       "A ribbon fully inside its street's surface adds no fill of its own")
        XCTAssertEqual(automobile.casing.drawing.indices.count,
                       surfaceOnly.drawingRoadPhases.automobileGround.casing.drawing.indices.count,
                       "and no kerb of its own inside the surface")
        // Positional guard: the fill sits where the ring is, in render space
        // (y 2796...3296), never in its mirror band. Counts alone cannot
        // tell a mirrored surface from the real one.
        for vertex in automobile.fill.drawing.vertices {
            XCTAssertTrue((2788...3304).contains(Int(vertex.position.y)),
                          "A fill vertex left the ring's render band: y=\(vertex.position.y)")
        }
    }

    func testAGraphSurfaceSuppressesTheSynthesizedPaint() throws {
        let covered = try parse([surface(coveringRing), street([(1900, 1050), (2500, 1050)])])
        XCTAssertEqual(covered.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                       "The street's synthesized centre line ends where the measured surface begins")
        let bare = try parse([street([(1900, 1050), (2500, 1050)])])
        XCTAssertGreaterThan(bare.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "The same street alone paints its centre line as before")
    }

    func testAPartlyCoveredStreetKeepsDrawingOutsideTheSurface() throws {
        let long = street([(200, 1050), (3800, 1050)])
        let partly = try parse([surface(coveringRing), long])
        let surfaceOnly = try parse([surface(coveringRing)])
        XCTAssertGreaterThan(partly.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                             surfaceOnly.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                             "The pieces of the ribbon outside the surface keep drawing")
    }

    private func marking(_ points: [(Int32, Int32)], kind: String = "dividing",
                         id: UInt64 = 9) -> VectorTileFixture.Feature {
        .init(id: id, geometry: .line(points: points), properties: ["marking": kind])
    }

    func testShippedPaintSurvivesInsideTheSurfacesItLiesOn() throws {
        // The measured centre line lies inside the graph surface on purpose:
        // that is where the paint is. The surface clips the synthesized paint
        // and leaves the shipped line alone.
        let parsed = try parse([surface(coveringRing),
                                street([(1900, 1050), (2500, 1050)]),
                                marking([(1900, 1050), (2500, 1050)])])
        XCTAssertGreaterThan(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "The shipped line draws where the synthesized paint is gone")
    }

    func testShippedPaintNeitherJoinsNorCutsTheStreetsItTouches() throws {
        // A street with an interior vertex, and a marking ending exactly on
        // it. If the marking counted as a street, that point would become a
        // junction and the street's own centre line would be cut and inset
        // there; if the street's surface machinery touched the marking, its
        // geometry would change. Both stay exactly the sum of their parts.
        let bentStreet = street([(400, 2050), (2048, 2050), (3700, 2100)])
        let together = try parse([bentStreet, marking([(2048, 2050), (2048, 1200)])])
        let streetAlone = try parse([bentStreet])
        let markingAlone = try parse([marking([(2048, 2050), (2048, 1200)])])
        XCTAssertEqual(together.drawingRoadPhases.automobileGround.detail.drawing.indices.count,
                       streetAlone.drawingRoadPhases.automobileGround.detail.drawing.indices.count
                           + markingAlone.drawingRoadPhases.automobileGround.detail.drawing.indices.count,
                       "Street paint and shipped paint coexist without splitting each other")
    }

    func testABridgeSurfaceDoesNotClipTheStreetUnderIt() throws {
        // A deck polygon above a ground street: different structure, so the
        // street is not the deck's ground and keeps its ribbon.
        let deck = surface(coveringRing, extra: ["brunnel": "bridge", "layer": "1"])
        let withDeck = try parse([deck, street([(1900, 1050), (2500, 1050)])])
        let bare = try parse([street([(1900, 1050), (2500, 1050)])])
        XCTAssertEqual(withDeck.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                       bare.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                       "The ground street draws exactly as it does without the deck")
        XCTAssertGreaterThan(withDeck.drawingRoadPhases.bridge.fill.drawing.indices.count, 0,
                             "while the deck surface draws in the bridge phases")
    }

    // MARK: Tunnels

    /// The tunnel's centreline as the tiles ship it: `brunnel=tunnel`, the
    /// tunnel's layer, the street it belongs to.
    private func tunnelLine(_ points: [(Int32, Int32)], street: String? = "7") -> VectorTileFixture.Feature {
        var extra = ["brunnel": "tunnel", "layer": "-1"]
        if let street { extra["street"] = street }
        return self.street(points, id: 3, extra: extra)
    }

    func testATunnelSurfaceIsABareFillWithNoPaintInsideIt() throws {
        // The surface ships with the tunnel's layer and street but no
        // `brunnel`; the centreline of the same street says tunnel. The
        // measured lane paint inside the surface is exactly what a tunnel
        // never shows.
        let parsed = try parse([surface(coveringRing, extra: ["layer": "-1", "street": "7"]),
                                tunnelLine([(1900, 1050), (2500, 1050)]),
                                marking([(1900, 1050), (2500, 1050)])])
        XCTAssertGreaterThan(parsed.drawingRoadPhases.tunnel.fill.drawing.indices.count, 0,
                             "The surface draws in the tunnel phases")
        XCTAssertEqual(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                       "and the shipped paint inside it is gone")
        XCTAssertEqual(parsed.drawingRoadPhases.tunnel.detail.drawing.indices.count, 0,
                       "in every tier")
        XCTAssertEqual(parsed.drawingRoadPhases.automobileGround.fill.drawing.indices.count, 0,
                       "Nothing of it draws as open road")
    }

    func testShippedPaintOutsideATunnelSurfaceSurvives() throws {
        // A marking that starts inside the tunnel and runs on past it keeps
        // the part outside: only the covered stretch is cut.
        let parsed = try parse([surface(coveringRing, extra: ["layer": "-1", "street": "7"]),
                                tunnelLine([(1900, 1050), (2500, 1050)]),
                                marking([(2200, 1050), (3600, 1050)])])
        XCTAssertGreaterThan(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "The paint past the portal still draws")
    }

    func testAnUnderpassSurfaceIsNotATunnel() throws {
        // A street diving under a bridge ships as `layer=-1` without any
        // tunnel flag and is in full view from above: its surface keeps its
        // paint and never takes the tunnel look.
        let parsed = try parse([surface(coveringRing, extra: ["layer": "-1", "street": "7"]),
                                street([(1900, 1050), (2500, 1050)], extra: ["layer": "-1", "street": "7"]),
                                marking([(1900, 1050), (2500, 1050)])])
        XCTAssertGreaterThan(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "The paint under the bridge stays")
    }

    func testATunnelOfAnotherStreetDoesNotClaimTheSurface() throws {
        // A tunnel centreline of a different street, far from the polygon:
        // no match by id and none by containment.
        let parsed = try parse([surface(coveringRing, extra: ["layer": "-1", "street": "7"]),
                                tunnelLine([(300, 3500), (900, 3500)], street: "8"),
                                marking([(1900, 1050), (2500, 1050)])])
        XCTAssertGreaterThan(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "The surface is an ordinary underpass and keeps its paint")
    }

    /// The Arbat Gate layout in one tile: an ordinary street with its own
    /// surface and paint next to the tunnel. A style key is one baked colour
    /// per tile, so the tunnel must not share a key with the street: with the
    /// class key shared, the first tunnel in the tile made every road of its
    /// class in the tile translucent, and the tunnel span drew doubled.
    func testATunnelDoesNotTintTheOtherRoadsOfItsClassAndDrawsOnce() throws {
        let opacity = ImmersiveMapTilesDefaultMapStyle.tunnelFillOpacity
        let openSurface: [(Int32, Int32)] = [(600, 2400), (1400, 2400), (1400, 2900), (600, 2900)]
        let tunnel: [VectorTileFixture.Feature] = [
            surface(coveringRing, extra: ["layer": "-1", "street": "7"]),
            tunnelLine([(1900, 1050), (2500, 1050)]),
            marking([(1900, 1050), (2500, 1050)]),
        ]
        let open: [VectorTileFixture.Feature] = [
            surface(openSurface, id: 11, extra: ["street": "8"]),
            street([(700, 2650), (1300, 2650)], id: 12, extra: ["street": "8"]),
            marking([(700, 2650), (1300, 2650)], id: 13),
        ]
        // The tunnel comes first in the tile on purpose: that is the order
        // that poisoned the shared key.
        let parsed = try parse(tunnel + open)
        let surfaces = parsed.drawingRoadPhases.automobileGround.fill
        XCTAssertGreaterThan(surfaces.drawing.indices.count, 0, "The open street's surface draws")
        for style in surfaces.styles {
            XCTAssertEqual(style.color.w, 1, accuracy: 1e-6, "Every open-road fill in the tile stays opaque")
        }
        XCTAssertGreaterThan(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "and its paint still draws")
        let tunnelFill = parsed.drawingRoadPhases.tunnel.fill
        XCTAssertEqual(tunnelFill.styles.count, 1, "The tunnel bucket holds the tunnel's one style")
        XCTAssertEqual(tunnelFill.styles.first?.color.w ?? 1, opacity, accuracy: 1e-6,
                       "at the tunnel opacity")
        // The ribbon is clipped away under its surface, so the span is one
        // layer of fill: exactly the polygon alone.
        let surfaceAlone = try parse([surface(coveringRing, extra: ["layer": "-1", "street": "7"]),
                                      tunnelLine([(1900, 1050), (2500, 1050)])])
        XCTAssertEqual(tunnelFill.drawing.indices.count,
                       surfaceAlone.drawingRoadPhases.tunnel.fill.drawing.indices.count)
        let polygonOnly = try makeParser().parse(tile: tile, mvtData: VectorTileFixture.layerTile(
            layerName: "transportation",
            features: [surface(coveringRing, extra: ["layer": "-1", "street": "7", "brunnel": "tunnel"])]))
        XCTAssertEqual(surfaceAlone.drawingRoadPhases.tunnel.fill.drawing.indices.count,
                       polygonOnly.drawingRoadPhases.tunnel.fill.drawing.indices.count,
                       "The tunnel ribbon adds no fill of its own inside its surface")
    }

    func testATunnelCentrelineEndingJustOutsideItsSurfaceStillClaimsIt() throws {
        // The graph insets the surface behind a portal quad at each end, so
        // the centreline's endpoints lie a few units outside the polygon and
        // only its middle is in. No street id on either side.
        let parsed = try parse([surface(coveringRing, extra: ["layer": "-1"]),
                                tunnelLine([(1780, 1050), (2620, 1050)], street: nil),
                                marking([(1900, 1050), (2500, 1050)])])
        XCTAssertEqual(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                       "The paint inside the tunnel is gone")
    }

    func testATunnelSurfaceWithoutAStreetIdMatchesByContainment() throws {
        // No street id on either side: the centreline running inside the
        // polygon is what makes it the tunnel's surface.
        let parsed = try parse([surface(coveringRing, extra: ["layer": "-1"]),
                                tunnelLine([(1900, 1050), (2500, 1050)], street: nil),
                                marking([(1900, 1050), (2500, 1050)])])
        XCTAssertEqual(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                       "The paint inside the tunnel is gone")
        XCTAssertGreaterThan(parsed.drawingRoadPhases.tunnel.fill.drawing.indices.count, 0,
                             "and the surface draws as the tunnel")
    }
}
