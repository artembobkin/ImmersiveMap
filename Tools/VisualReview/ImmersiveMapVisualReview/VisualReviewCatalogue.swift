// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import SwiftUI

/// One thing a person looks at and judges.
///
/// A scenario is a fixed description of a picture: the same settings, the same
/// camera, the same date, every time it is rendered. That is what makes two
/// runs comparable and lets the tool tell you which pictures actually changed
/// since you last approved them.
struct VisualReviewScenario: Identifiable {
    enum Subject {
        /// One frame, optionally with routes drawn over it.
        ///
        /// Routes live here rather than on the scenario because video export
        /// cannot draw them: its runtime hands the renderer an empty route
        /// source. A scenario that carried routes for either subject would
        /// render them in a still and silently omit them from a clip, and the
        /// reviewer would be judging a picture the tool never claimed to make.
        case still(camera: ImmersiveMapCameraPosition, routes: [ImmersiveMapRoute])
        /// A short clip. `establish` is where the camera starts, `shots` is
        /// the tour it then flies.
        case video(establish: ImmersiveMapCameraPosition, shots: [ImmersiveMapCameraTourShot])

        static func still(camera: ImmersiveMapCameraPosition) -> Subject {
            .still(camera: camera, routes: [])
        }
    }

    /// The canvas a still is rendered onto.
    ///
    /// Both halves matter and neither can be inferred from the other: the pixel
    /// dimensions decide how much map is in frame, and the scale decides how
    /// big a point is, which is what sizes the labels. A phone is not a small
    /// desktop window; it is a small window with a dense display, and only
    /// rendering both together shows what a reader actually gets.
    struct Output {
        let width: Int
        let height: Int
        let pixelsPerPoint: CGFloat

        /// Big enough to judge label legibility and building edges, small
        /// enough that a full pass is quick.
        static let desktop = Output(width: 1600, height: 1000, pixelsPerPoint: 2)

        /// A 3x phone in portrait, at the point dimensions of a current large
        /// iPhone. The densest display the engine targets and the smallest
        /// canvas, so it is where undersized type shows up first.
        static let phone = Output(width: 1206, height: 2622, pixelsPerPoint: 3)
    }

    /// Stable across runs and across renames of the title: it is the key the
    /// verdict file is written under, so changing it forgets the verdict.
    let id: String
    /// What the reviewer sees as the name of the picture.
    let title: String
    /// What to look at, in words. The point of the scenario, so the reviewer
    /// is judging the same thing this time as last time.
    let lookFor: String
    let settings: ImmersiveMapSettings
    let subject: Subject
    let output: Output

    var isVideo: Bool {
        if case .video = subject { return true }
        return false
    }

    init(id: String,
         title: String,
         lookFor: String,
         settings: ImmersiveMapSettings,
         subject: Subject,
         output: Output = .desktop) {
        self.id = id
        self.title = title
        self.lookFor = lookFor
        // Every scenario renders the hosted endpoint through the one-line
        // template; the API key comes from `IMMERSIVEMAP_API_KEY` in the
        // environment or from the gitignored `LocalSecrets.plist` at the
        // repository root, so it never lands in the repository, and without
        // it the render runs on the shared anonymous pool.
        self.settings = settings.tileURLTemplate(
            "https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt",
            headers: Self.hostedTileHeaders())
        self.subject = subject
        self.output = output
    }

    private static func hostedTileHeaders() -> [String: String] {
        guard let key = localAPIKey(), key.isEmpty == false else {
            return [:]
        }
        return ["Authorization": "Bearer \(key)"]
    }

    /// The environment wins (the scheme carries an empty placeholder for it);
    /// otherwise the key comes from the gitignored `LocalSecrets.plist` at
    /// the repository root, read live off the checkout where possible (the
    /// Mac, the simulator) and from the copy the "Bundle LocalSecrets" build
    /// phase put into the app on a phone, which cannot see the Mac's files.
    private static func localAPIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["IMMERSIVEMAP_API_KEY"],
           key.isEmpty == false {
            return key
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                let secrets = directory.appendingPathComponent("LocalSecrets.plist")
                if let key = NSDictionary(contentsOf: secrets)?["IMMERSIVEMAP_API_KEY"] as? String,
                   key.isEmpty == false {
                    return key
                }
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        guard let bundled = Bundle.main.url(forResource: "LocalSecrets", withExtension: "plist") else {
            return nil
        }
        return NSDictionary(contentsOf: bundled)?["IMMERSIVEMAP_API_KEY"] as? String
    }
}

/// The scenes that get looked at before a release.
///
/// The list is meant to be edited: add a scenario when a feature ships, and it
/// joins the pre-release pass from then on. Keep the identifiers stable, since
/// they carry the verdict history.
enum VisualReviewCatalogue {
    /// Pinned so the sun, the terminator and the night side land in the same
    /// place every run. A moving sun would make every scene differ from the
    /// last approval for a reason that has nothing to do with the code.
    static let sceneDate = Date(timeIntervalSince1970: 1_749_000_000)

    /// Places chosen for what they contain rather than for sentiment: dense
    /// blocks with towers, water against a coastline, and mountains.
    private enum Place {
        static let manhattan = ImmersiveMapCameraPosition(latitudeDegrees: 40.7549,
                                                          longitudeDegrees: -73.9840,
                                                          zoom: 16,
                                                          bearing: 0.6,
                                                          pitch: 0.9)
        static let manhattanFlat = ImmersiveMapCameraPosition(latitudeDegrees: 40.7549,
                                                              longitudeDegrees: -73.9840,
                                                              zoom: 15)
        static let sanFrancisco = ImmersiveMapCameraPosition(latitudeDegrees: 37.8100,
                                                             longitudeDegrees: -122.4100,
                                                             zoom: 13)
        static let kremlin = ImmersiveMapCameraPosition(latitudeDegrees: 55.7517,
                                                        longitudeDegrees: 37.6178,
                                                        zoom: 15.6,
                                                        bearing: 0.4,
                                                        pitch: 0.9)
        static let tverskaya = ImmersiveMapCameraPosition(latitudeDegrees: 55.7570,
                                                          longitudeDegrees: 37.6135,
                                                          zoom: 16.4,
                                                          bearing: 0.3,
                                                          pitch: 0.5)
        /// The same junction one tile level out: the camera sits in the band
        /// z15 tiles serve, which is where the street has to draw everything
        /// the z16 shot draws.
        static let tverskayaOneLevelOut = ImmersiveMapCameraPosition(latitudeDegrees: 55.7570,
                                                                     longitudeDegrees: 37.6135,
                                                                     zoom: 15.4,
                                                                     bearing: 0.3,
                                                                     pitch: 0.5)
        /// The Boulevard Ring diving under Novy Arbat at Arbat Gate square:
        /// the one covered stretch of a vehicular tunnel in the centre.
        static let arbatTunnel = ImmersiveMapCameraPosition(latitudeDegrees: 55.7522,
                                                            longitudeDegrees: 37.6016,
                                                            zoom: 17.0,
                                                            bearing: 0.0,
                                                            pitch: 0.0)
        static let okhotnyParking = ImmersiveMapCameraPosition(latitudeDegrees: 55.7577,
                                                               longitudeDegrees: 37.6156,
                                                               zoom: 16.5,
                                                               bearing: 0.3,
                                                               pitch: 0.4)
        static let centralRussia = ImmersiveMapCameraPosition(latitudeDegrees: 55.7,
                                                              longitudeDegrees: 37.6,
                                                              zoom: 5)
        static let alps = ImmersiveMapCameraPosition(latitudeDegrees: 46.02,
                                                     longitudeDegrees: 7.75,
                                                     zoom: 10)
        static let europe = ImmersiveMapCameraPosition(latitudeDegrees: 48.0,
                                                       longitudeDegrees: 10.0,
                                                       zoom: 4)
        static let easternEurope = ImmersiveMapCameraPosition(latitudeDegrees: 56.35,
                                                              longitudeDegrees: 38.0,
                                                              zoom: 4.5)
        static let globe = ImmersiveMapCameraPosition(latitudeDegrees: 20.0,
                                                      longitudeDegrees: 10.0,
                                                      zoom: 1)
        static let wholePlanet = ImmersiveMapCameraPosition(latitudeDegrees: 20.0,
                                                            longitudeDegrees: 10.0,
                                                            zoom: 0)
    }

    static let scenarios: [VisualReviewScenario] = [
        VisualReviewScenario(
            id: "labels.phone.streets",
            title: "Street labels on a 3x phone",
            lookFor: """
            Read them, do not just see them. Street names, POIs and house \
            numbers should all be comfortably readable at arm's length, with \
            open counters in a, e and o rather than letters closed up by their \
            halo. Nothing should be so large that the map disappears under the \
            type, and labels should be thinned out enough to leave the streets \
            visible between them. A POI is a disc with its name beside it: \
            check that the pair reads as one mark on the map rather than as a \
            button dropped onto it, and that the name does not outweigh the \
            street it stands on. Every POI on screen carries an icon; a name \
            standing alone, with no disc, is a bug.
            """,
            settings: .default,
            subject: .still(camera: Place.manhattanFlat),
            output: .phone),

        VisualReviewScenario(
            id: "labels.phone.overview",
            title: "Settlement labels on a 3x phone",
            lookFor: """
            City, town and water labels at an overview zoom on a small dense \
            screen. Sizes should step visibly between the classes, the halo \
            should separate the type from the landcover without swallowing it, \
            and neighbouring labels should not overlap.
            """,
            settings: .default,
            subject: .still(camera: Place.sanFrancisco),
            output: .phone),

        VisualReviewScenario(
            id: "globe.default",
            title: "Globe, default style",
            lookFor: """
            The planet is round with no seam down the middle, the coastlines are \
            clean, and the terminator falls where the pinned date puts it. Stars \
            behind it, no banding in the space gradient. A soft sky-blue \
            atmosphere hugs the whole limb, brighter on the day side and a \
            thin residual glow on the night side, whitening right at the \
            edge, with no gap between the halo and the sphere and no hard \
            ring; the surface itself lifts toward the same blue at the limb. \
            Country borders are thin, unobtrusive dashed lines that read as \
            dashes, not chains of fat dots, and no regional borders clutter \
            the planet.
            """,
            settings: .default,
            subject: .still(camera: Place.globe)),

        VisualReviewScenario(
            id: "globe.atmosphere.off",
            title: "Globe with the atmosphere off",
            lookFor: """
            The control for the frame above: the same planet with a hard limb \
            against space, no halo and no glow toward the edge. The sun's warm \
            rim on the day side is still there (that is the earth scene, not \
            the atmosphere).
            """,
            settings: .default.atmosphere(isEnabled: false),
            subject: .still(camera: Place.globe)),

        VisualReviewScenario(
            id: "globe.atmosphere.tilted",
            title: "Atmosphere on a tilted, off-center globe",
            lookFor: """
            The camera is pitched and the planet fills the lower frame, so its \
            silhouette is no longer a circle. The halo must still hug the limb \
            all the way along, at the same width, without detaching on one \
            side or crossing onto the surface on the other.
            """,
            settings: .default,
            subject: .still(camera: ImmersiveMapCameraPosition(latitudeDegrees: 20.0,
                                                               longitudeDegrees: 10.0,
                                                               zoom: 3.4,
                                                               bearing: 0.4,
                                                               pitch: 0.7))),

        VisualReviewScenario(
            id: "globe.transparent.space",
            title: "Globe over transparent space",
            lookFor: """
            Everything outside the planet is fully transparent against the \
            checkerboard, with no halo or dark fringe at the limb.
            """,
            settings: .default.transparentSpace(),
            subject: .still(camera: Place.globe)),

        VisualReviewScenario(
            id: "globe.whole.planet.deep",
            title: "Whole planet at zoom 0, deep colours",
            lookFor: """
            The sphere small against black, wearing richer and darker colours \
            than the map palette: the sea a deeper blue, the land a fuller \
            green, the deserts warm rather than pale. It should read as a \
            planet seen from space, not as a washed-out map wrapped on a ball, \
            and not as a dark, muddy one either: coastlines stay crisp and the \
            ice caps stay white. Compare with the zoom 1 scenes: the same \
            palette, half as deep there, and gone by zoom 2. The polar cap and \
            any tile still loading must not show in a paler colour than the \
            rest of the surface.
            """,
            settings: .default,
            subject: .still(camera: Place.wholePlanet)),

        VisualReviewScenario(
            id: "globe.no.earth.scene",
            title: "Globe with the earth scene off",
            lookFor: "Flat, evenly lit planet: no sun, no night side, no glow.",
            settings: .default.earthScene(isEnabled: false),
            subject: .still(camera: Place.globe)),

        VisualReviewScenario(
            id: "transition.continental",
            title: "Continental zoom, mid transition",
            lookFor: """
            The point where the sphere is turning into a plane. Curvature still \
            reads at the edges, labels stay upright, and tiles line up across \
            the seam.
            """,
            settings: .default,
            subject: .still(camera: Place.europe)),

        VisualReviewScenario(
            id: "lines.globe.borders",
            title: "Country borders on the globe",
            lookFor: """
            Thin lines on the sphere, where the atlas has no MSAA and only the \
            analytic antialiasing keeps their edges. Border dashes should read \
            as clean, evenly spaced dashes with soft edges and softened cut \
            ends, not dots or a smeared quasi-solid line, and the line should \
            hold one width along its length instead of rippling. The width is \
            point-locked: zooming within a level must not visibly fatten it, \
            nor snap it at the next level. The dash pattern is anchored to \
            the map: panning or rotating must not make the dashes crawl along \
            the border. No roads this far out (the motorway skeleton fades \
            in from z5), and the major rivers read as thin pale-blue threads \
            rather than vanishing.
            """,
            settings: .default,
            subject: .still(camera: Place.easternEurope)),

        VisualReviewScenario(
            id: "landcover.overview.plain",
            title: "Central Russia, country-view landcover",
            lookFor: """
            A farmed plain at region scale, the hardest case for the biome \
            palette. The ground and the cropland read as two close warm \
            creams, forests as soft green shapes on them, nothing camouflage: \
            no field of green-on-green blotches with visible raster edges. \
            Regional borders are a quiet pale dash, distinctly softer than \
            the national ones; the motorway skeleton reads as slim dark \
            ribbons, clearly drawn strokes rather than hairline cracks, and \
            still does not dominate; lakes stay legible.
            """,
            settings: .default,
            subject: .still(camera: Place.centralRussia)),

        VisualReviewScenario(
            id: "terrain.alps",
            title: "Alps, terrain and landcover",
            lookFor: """
            Rock, snow, forest and water read as distinct bands rather than \
            mush, and the contour of the ridges follows the valleys.
            """,
            settings: .default,
            subject: .still(camera: Place.alps)),

        VisualReviewScenario(
            id: "coast.san.francisco",
            title: "San Francisco, coastline and labels",
            lookFor: """
            Water meets land with no gaps or overshoot, the bridges read as \
            bridges, and place labels are legible and not colliding.
            """,
            settings: .default,
            subject: .still(camera: Place.sanFrancisco)),

        VisualReviewScenario(
            id: "buildings.shadows",
            title: "Manhattan, buildings and shadows",
            lookFor: """
            Towers are extruded solid, with light roofs a step under the \
            ground and no z-fighting on the walls. Roof, sun-facing wall, side \
            wall and shaded wall read as four tones of one warm grey, and the \
            walls darken toward the street. Shadows are soft and cool (a light \
            blue-grey, never a black or neutral grey stain), fall away from \
            the sun, land on the ground and on lower roofs, and have no \
            visible cascade seam across the frame.
            """,
            settings: .default,
            subject: .still(camera: Place.manhattan)),

        VisualReviewScenario(
            id: "buildings.shadows.off",
            title: "Manhattan with shadows off",
            lookFor: """
            The control for the frame above: same scene, no shadows at all. \
            Facades keep their own shading, nothing goes flat grey.
            """,
            settings: .default.shadows(isEnabled: false),
            subject: .still(camera: Place.manhattan)),

        VisualReviewScenario(
            id: "buildings.translucent",
            title: "Manhattan with translucent buildings",
            lookFor: """
            The composited path, no longer the default: streets and labels \
            show through the massing at the blend alpha, the roofs carry the \
            ground shadow under them, and nothing z-fights or double-tints \
            where buildings overlap.
            """,
            settings: .default.buildingExtrusionMode(.translucent),
            subject: .still(camera: Place.manhattan)),

        VisualReviewScenario(
            id: "buildings.roofs.kremlin",
            title: "Kremlin, shaped roofs",
            lookFor: """
            The one tile with every roof shape in it. Where the tiles carry \
            roof tags: gable ridges run along their building, not diagonally \
            to it, and gable ends close as vertical triangles up to the \
            ridge; the Kremlin wall's merlons read as small aligned gables, \
            not stray fins; tower tents rise as clean pyramids from their \
            eaves with nothing creased and no edge cutting through a wall; \
            domes are smooth caps, skillions a single tilted plane. Nothing \
            z-fights, and every sloped face is lit from above. A building \
            the engine cannot shape honestly wears a flat lid, which is \
            correct, not a regression.
            """,
            settings: .default,
            subject: .still(camera: Place.kremlin)),

        VisualReviewScenario(
            id: "roads.carriageways.street",
            title: "Street level, carriageways and lane markings",
            lookFor: """
            Roads as surfaces, not strokes: a wide avenue is visibly wider \
            than the side street it crosses, in the proportion the real \
            streets are, and each carriageway carries a dashed lane divider \
            down its middle. The dashes stay a painted marking (constant \
            weight, evenly spaced) rather than growing into a second road, \
            junctions do not blob where markings meet, and the kerb is a thin \
            even edge on both sides instead of a wide dark band. Service \
            alleys and footways carry no markings.
            """,
            settings: .default,
            subject: .still(camera: Place.manhattan)),

        VisualReviewScenario(
            id: "roads.osm2streets.tverskaya",
            title: "Tverskaya junction, measured streetscape",
            lookFor: """
            Where the tiles carry the measured streetscape (central Moscow \
            test builds): the junction is ONE surface, flush with every \
            street entering it, no ribs and no seams inside it; each \
            carriageway is a single polygon with one thin even kerb; lane \
            separators are short even dashes that stop at the junction edge \
            instead of running across it; the centre line is a longer dash, \
            the carriageway edge a thin solid line; crossings are zebra \
            stripes inside the junction, drawn once. The palette stays the \
            light asphalt grey. Where the tiles carry no streetscape the \
            streets draw exactly as before, and the boundary between the two \
            is not a visible seam.
            """,
            settings: .default,
            subject: .still(camera: Place.tverskaya)),

        VisualReviewScenario(
            id: "roads.osm2streets.tverskaya.z15",
            title: "Tverskaya junction one zoom level out",
            lookFor: """
            The same junction a level coarser, where the engine is serving \
            z15 tiles instead of z16: it must carry the SAME figures as the \
            shot above, only smaller. Lane separators, centre lines, zebra \
            crossings, the letters A of the bus lane and the parking bay \
            combs are all present; nothing is missing that the closer shot \
            has, and nothing new appears. The paint is fainter and finer \
            here, which is the camera-zoom fade doing its work, but it is \
            paint rather than grey mush, and the dashes still sit on the \
            asphalt as separate marks. Zooming in past 16 must not pop \
            anything into existence.
            """,
            settings: .default,
            subject: .still(camera: Place.tverskayaOneLevelOut)),

        VisualReviewScenario(
            id: "roads.tunnel.arbat",
            title: "Arbat Gate, the Boulevard Ring under Novy Arbat",
            lookFor: """
            The two carriageways of the Boulevard Ring run north-south \
            through the square and pass UNDER Novy Arbat. On both sides of \
            the avenue the covered stretch is a faint ghost of the road: the \
            asphalt grey at twenty percent over the ground, a flat fill with \
            no kerb, no lane dashes and no edge line on it, ending square \
            where the open road resumes with its full grey and its paint. \
            Novy Arbat itself is solid, its lane paint runs through the \
            crossing unbroken, and nothing of the tunnel shows through it. \
            No white dashes float over the ghost, and the ghost does not \
            continue as a lighter band across the avenue.
            """,
            settings: .default,
            subject: .still(camera: Place.arbatTunnel)),

        VisualReviewScenario(
            id: "roads.parking.okhotny",
            title: "Okhotny Ryad, parking lots",
            lookFor: """
            The parking strips along Okhotny Ryad and by the State Duma are \
            asphalt with a thin kerb, and each carries the comb of parking \
            bays: short white stripes across the strip, evenly spaced, never \
            poking past the kerb. A deep lot reads as rows of bays separated \
            by clean aisles; parking aisles inside a lot carry no kerb of \
            their own. The dedicated bus lane along Okhotny \
            Ryad carries large white letters A stamped along it, feet toward \
            the oncoming driver, with no recolored surface under them, and \
            the comb never climbs onto it or onto any carriageway. At the \
            bus stops the kerb carries the yellow sawtooth of the stop \
            marking, anchored to the edge of the roadway.
            """,
            settings: .default,
            subject: .still(camera: Place.okhotnyParking)),

        VisualReviewScenario(
            id: "roads.labels.flat",
            title: "Manhattan flat, roads and road labels",
            lookFor: """
            The palette at street level: a warm off-white ground, every \
            drive tier one light asphalt grey with width carrying the \
            hierarchy, a thin darker kerb, light blue water and soft green \
            parks; nothing dark competes with the labels. Road casings are \
            even, junctions do not blob, and road labels follow the street, \
            stay upright, and do not repeat on top of each other.
            """,
            settings: .default,
            subject: .still(camera: Place.manhattanFlat)),

        VisualReviewScenario(
            id: "routes.globe",
            title: "Route arcs over the globe",
            lookFor: """
            The arcs lift off the surface cleanly, keep an even width along \
            their length, and are hidden where they pass behind the planet.
            """,
            settings: .default.earthScene(isEnabled: false),
            subject: .still(camera: Place.globe, routes: [
                ImmersiveMapRoute(id: 1,
                                  path: ImmersiveMapGeoPath(from: GeoCoordinate(latitude: 40.64, longitude: -73.78),
                                                            to: GeoCoordinate(latitude: 51.47, longitude: -0.45),
                                                            peakAltitudeMeters: 700_000),
                                  color: SIMD4<Float>(1, 0.35, 0.1, 1),
                                  widthPoints: 5,
                                  progress: 1),
                ImmersiveMapRoute(id: 2,
                                  path: ImmersiveMapGeoPath(from: GeoCoordinate(latitude: 35.55, longitude: 139.78),
                                                            to: GeoCoordinate(latitude: 25.25, longitude: 55.36),
                                                            peakAltitudeMeters: 500_000),
                                  color: SIMD4<Float>(0.2, 0.7, 1, 1),
                                  widthPoints: 5,
                                  progress: 0.6)
            ])),

        VisualReviewScenario(
            id: "video.globe.to.street",
            title: "Flight from globe to street level",
            lookFor: """
            Watch the whole descent: the sphere flattens without a jump, tiles \
            arrive ahead of the camera rather than popping in under it, and \
            labels fade instead of blinking. Nothing should flicker at the \
            moment buildings appear.
            """,
            settings: .default,
            subject: .video(
                establish: Place.globe,
                shots: [
                    ImmersiveMapCameraTourShot(position: Place.europe,
                                               options: CameraFlightOptions(duration: 2.5,
                                                                            routeStyle: .greatCircle,
                                                                            altitudeStyle: .direct),
                                               holdAfter: 0.4),
                    ImmersiveMapCameraTourShot(position: Place.manhattanFlat,
                                               options: CameraFlightOptions(duration: 3.0,
                                                                            routeStyle: .automatic,
                                                                            altitudeStyle: .overviewFirst),
                                               holdAfter: 0.4),
                    ImmersiveMapCameraTourShot(position: Place.manhattan,
                                               options: CameraFlightOptions(duration: 2.0,
                                                                            routeStyle: .automatic,
                                                                            altitudeStyle: .direct),
                                               holdAfter: 1.0)
                ])),

        VisualReviewScenario(
            id: "video.orbit.buildings",
            title: "Orbit around the Manhattan skyline",
            lookFor: """
            Shadows swing with the bearing and stay attached to their towers. \
            Watch for shadow cascades snapping, buildings shimmering along their \
            edges, and labels detaching from their anchors while the camera moves.
            """,
            settings: .default,
            subject: .video(
                establish: Place.manhattan,
                shots: [
                    ImmersiveMapCameraTourShot(
                        position: ImmersiveMapCameraPosition(latitudeDegrees: 40.7549,
                                                             longitudeDegrees: -73.9840,
                                                             zoom: 16,
                                                             bearing: 2.7,
                                                             pitch: 0.9),
                        options: CameraFlightOptions(duration: 4.0,
                                                     routeStyle: .automatic,
                                                     altitudeStyle: .direct),
                        holdAfter: 0.5)
                ]))
    ]
}

extension ImmersiveMapView {
    /// Applies a whole settings value to the view.
    ///
    /// The view takes its configuration one branch at a time, and a scenario
    /// carries the assembled value, because the still recorder takes that same
    /// value directly. Fanning it out here keeps one description of a scene
    /// driving both the still and the video path, so the video cannot quietly
    /// render something the still never showed.
    func applying(_ settings: ImmersiveMapSettings) -> ImmersiveMapView {
        self
            .renderLoopSettings(settings.renderLoop)
            .cameraSettings(settings.camera)
            .presentationSettings(settings.presentation)
            .mapStyle(settings.mapStyle)
            .tileSettings(settings.tiles)
            .labelSettings(settings.labels)
            .sceneSettings(settings.scene)
            .styleSettings(settings.style)
            .avatarSettings(settings.avatars)
            .attributionSettings(settings.attribution)
            .postProcessingSettings(settings.postProcessing)
            .debugSettings(settings.debug)
    }
}
