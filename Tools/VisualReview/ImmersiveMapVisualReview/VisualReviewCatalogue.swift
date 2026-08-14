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
        self.settings = settings
        self.subject = subject
        self.output = output
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
            visible between them.
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
            behind it, no banding in the space gradient. Country borders are \
            thin, unobtrusive dashed lines that read as dashes, not chains of \
            fat dots, and no regional borders clutter the planet.
            """,
            settings: .default,
            subject: .still(camera: Place.globe)),

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
            the border. Only motorways and trunks show at this zoom, fading \
            in as faint smooth hairlines with their casing under the fill, \
            not a grey net of every road the tiles ship.
            """,
            settings: .default,
            subject: .still(camera: Place.easternEurope)),

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
            Towers are extruded with flat roofs and no z-fighting on the walls. \
            Shadows fall away from the sun, land on the ground and on lower \
            roofs, and have no visible cascade seam across the frame.
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
            id: "roads.labels.flat",
            title: "Manhattan flat, roads and road labels",
            lookFor: """
            Road casings are even, junctions do not blob, and road labels follow \
            the street, stay upright, and do not repeat on top of each other.
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
            .tileProvider(settings.tileProvider)
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
