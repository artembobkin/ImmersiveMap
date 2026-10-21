// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import ImmersiveMap
import UniformTypeIdentifiers

/// Renders the README's frames and lays out its gallery: every frame of
/// `frames.json` with a camera is captured offscreen by the engine's still
/// capture (`ImmersiveMapStillRecorder`) and written as a PNG into
/// `Assets/`, then the gallery between the README's markers
/// (`<!-- gallery:start -->` and `<!-- gallery:end -->`) is written again
/// from the list, in its order: a `full` frame takes a row of its own, the
/// `half` frames stand two to a row. So the pictures on the repository's
/// front page are made again, and a new one placed, by one command.
///
///     Tools/ReadmeFrames/render.sh
///     Tools/ReadmeFrames/render.sh --only readme-globe-europe
///     Tools/ReadmeFrames/render.sh --gallery-only
///     Tools/ReadmeFrames/render.sh --frames my.json --out /tmp/frames
///
/// Through `render.sh`, which builds with xcodebuild: a plain `swift run`
/// ships the engine's shader sources without compiling them, and the
/// capture cannot draw. The frames are always written in full: the engine
/// draws no attribution into a capture, so a picture published from here
/// needs the credit beside it, as the README has.
///
/// A frame is a place in the gallery and, when it has a camera, a render
/// (`Frame`): its name (the PNG's name under `Assets/`), the picture's
/// `alt` text and its `layout`, and the camera's latitude, longitude and
/// zoom, its bearing and pitch in degrees (0 by default), the output's
/// width and height in pixels, the pixels per point (2 by default, a
/// Retina screen) and the scene's date (a fixed summer noon by default, so
/// the sun and the night side are the same on every run). A frame without
/// a camera is placed as the PNG already in `Assets/`: a picture taken by
/// hand, until it gets a camera. A frame may name a `theme` (`night`,
/// the dark palette of the settings example), carry `avatars` (markers
/// with a portrait from a URL or a file, a battery or a speed badge) and
/// `sceneModels` (a USDZ file of the repository placed on the map), all
/// drawn into the capture. The map is the Develop app's: the hosted tiles
/// (or the local copy at `LocalTiles/`, or `IMMERSIVEMAP_DEV_TILE_ARCHIVE`),
/// the ground relief, the extruded buildings from zoom 14 and the model
/// archive.
///
/// Every frame starts from the network when there is no local archive, so
/// a frame takes as long as its tiles take to arrive, up to `settleTimeout`.
@main
struct ReadmeFrames {
    @MainActor
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let frames = try Frame.load(from: options.framesURL)
            let rendered = frames.filter { frame in
                frame.camera != nil && (options.only == nil || options.only == frame.name)
            }
            if options.galleryOnly == false {
                guard rendered.isEmpty == false else {
                    throw ToolError("No frame to render: \(options.only.map { "no frame named \($0) with a camera" } ?? "no frame has a camera")")
                }
                try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
                let recorder = ImmersiveMapStillRecorder()
                for frame in rendered {
                    guard let camera = frame.camera else { continue }
                    let started = Date()
                    print("\(frame.name): \(frame.width ?? Frame.defaultWidth)x\(frame.height ?? Frame.defaultHeight) at z\(frame.zoom ?? 0) \(frame.latitude ?? 0), \(frame.longitude ?? 0)")
                    let image = try await recorder.capture(settings: Self.mapSettings(theme: frame.theme),
                                                           camera: camera,
                                                           avatars: try frame.avatarMarkers(),
                                                           sceneModels: try frame.sceneModelValues(),
                                                           configuration: frame.configuration(settleTimeout: options.settleTimeout))
                    let url = options.outputDirectory.appendingPathComponent("\(frame.name).png")
                    try Self.writePNG(image, to: url)
                    print("  -> \(url.path) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                }
            }
            if options.only == nil {
                try Gallery.write(frames: frames, readme: options.readmeURL, assets: options.outputDirectory)
                print("gallery: \(frames.count) pictures in \(options.readmeURL.path)")
            }
        } catch {
            FileHandle.standardError.write(Data("readme-frames: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The map the frames are taken of: the Develop app's configuration, so
    /// a frame shows what the person at the screen sees there, without the
    /// controls and the debug panel, which the capture never draws anyway.
    /// The theme is the frame's (`Palette`), the default's by default.
    static func mapSettings(theme: Palette?) -> ImmersiveMapSettings {
        ImmersiveMapSettings.default
            .tileArchive(tileArchive)
            .mapStyle(ProtomapsBasemapMapStyle(theme: (theme ?? .day).theme).apply { theme in
                theme.features.buildingExtrusion = true
            })
            .buildingExtrusion(buildingsMinimumZoom: 14, risesFromTheGround: false)
            .groundRelief(isEnabled: true)
            .modelArchive(modelArchive, depthBias: 0.05)
            .labelSettings(language: .english)
    }

    /// The tile source, as the Develop app finds it: the environment, the
    /// local copy of the hosted archive, or the hosted archive.
    static var tileArchive: URL {
        if let value = ProcessInfo.processInfo.environment["IMMERSIVEMAP_DEV_TILE_ARCHIVE"],
           value.isEmpty == false,
           let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value) {
            return url
        }
        let hosted = ImmersiveMapTilesService.tileArchiveURL
        let local = repositoryRoot.appendingPathComponent("LocalTiles").appendingPathComponent(hosted.lastPathComponent)
        return FileManager.default.fileExists(atPath: local.path) ? local : hosted
    }

    static var modelArchive: URL {
        if let value = ProcessInfo.processInfo.environment["IMMERSIVEMAP_DEV_MODEL_ARCHIVE"],
           value.isEmpty == false,
           let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value) {
            return url
        }
        return ImmersiveMapTilesService.modelArchiveURL
    }

    /// The root of the repository, found from this file: the tool runs from
    /// the source tree, never shipped.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // readme-frames
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // ReadmeFrames
        .deletingLastPathComponent()  // Tools
        .deletingLastPathComponent()  // repository root

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolError("Cannot create \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ToolError("Cannot write \(url.path)")
        }
    }
}

/// One frame of the list: its place in the gallery, and where the camera
/// is and what comes out when it has one.
struct Frame: Decodable {
    /// Where the picture stands in the gallery: a row of its own, the
    /// width of the page, or two to a row.
    enum Layout: String, Decodable {
        case full
        case half
    }

    static let defaultWidth = 2400
    static let defaultHeight = 1720

    /// The file's name under the output directory, without the extension.
    let name: String
    /// The picture's alt text in the README. The name by default.
    let alt: String?
    /// `half` by default: the first frame of a gallery is the one to make `full`.
    let layout: Layout?
    /// The camera. A frame without one is placed in the gallery as the
    /// PNG already in `Assets/` and never rendered.
    let latitude: Double?
    let longitude: Double?
    let zoom: Double?
    /// Degrees, clockwise from north. 0 by default.
    let bearing: Double?
    /// Degrees from straight down. 0 by default.
    let pitch: Double?
    /// The output in pixels. 2400 by 1720 by default, the Develop app's
    /// window on a Retina screen.
    let width: Int?
    let height: Int?
    /// Pixels per layout point, what the point sizes of the style are
    /// measured against. 2 by default.
    let pixelsPerPoint: Double?
    /// The scene's wall date, ISO 8601, for the sun and the night side. A
    /// fixed summer noon over Europe by default.
    let sceneDate: Date?
    /// The palette the frame is drawn in: `day` by default, `night` for the
    /// dark one.
    let theme: Palette?
    /// Avatar markers drawn into the frame.
    let avatars: [Avatar]?
    /// 3D models placed on the map and drawn into the frame.
    let sceneModels: [SceneModel]?

    /// An avatar marker: a portrait from a URL (fetched before the capture,
    /// so the frame never shows the placeholder) or a file, and the badges.
    struct Avatar: Decodable {
        let id: UInt64
        let latitude: Double
        let longitude: Double
        /// A URL or a path, relative to the repository's root.
        let image: String
        let battery: Int?
        let speed: Int?

        func marker() throws -> AvatarMarker {
            let url = image.contains("://") ? URL(string: image) : ReadmeFrames.repositoryRoot.appendingPathComponent(image)
            guard let url, let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let portrait = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ToolError("Cannot load the portrait \(image) of avatar \(id)")
            }
            return AvatarMarker(id: id,
                                coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                                image: portrait,
                                batteryBadge: battery.map { AvatarBatteryBadge(levelPct: $0) },
                                speedBadge: speed.map { AvatarSpeedBadge(kilometersPerHour: $0) })
        }
    }

    /// A scene model: a USDZ file of the repository, by its path from the
    /// root, placed and sized on the map.
    struct SceneModel: Decodable {
        let id: UInt64
        let model: String
        let latitude: Double
        let longitude: Double
        let altitudeMeters: Double?
        let headingDegrees: Double?
        let pitchDegrees: Double?
        let fitDiameterMeters: Double?

        func value() throws -> ImmersiveMapSceneModel {
            let url = ReadmeFrames.repositoryRoot.appendingPathComponent(model)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError("No model file at \(url.path) for scene model \(id)")
            }
            return ImmersiveMapSceneModel(id: id,
                                          source: ImmersiveMapSceneModel.Source(url: url),
                                          coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                                          altitudeMeters: altitudeMeters ?? 0,
                                          headingDegrees: headingDegrees ?? 0,
                                          pitchDegrees: pitchDegrees ?? 0,
                                          fitDiameterMeters: fitDiameterMeters)
        }
    }

    func avatarMarkers() throws -> [AvatarMarker] {
        try (avatars ?? []).map { try $0.marker() }
    }

    func sceneModelValues() throws -> [ImmersiveMapSceneModel] {
        try (sceneModels ?? []).map { try $0.value() }
    }

    static let defaultSceneDate = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")!

    var camera: ImmersiveMapCameraPosition? {
        guard let latitude, let longitude, let zoom else { return nil }
        return ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                          longitudeDegrees: longitude,
                                          zoom: zoom,
                                          bearing: Float((bearing ?? 0) * .pi / 180),
                                          pitch: Float((pitch ?? 0) * .pi / 180))
    }

    func configuration(settleTimeout: TimeInterval) -> ImmersiveMapStillConfiguration {
        ImmersiveMapStillConfiguration(width: width ?? Self.defaultWidth,
                                       height: height ?? Self.defaultHeight,
                                       pixelsPerPoint: CGFloat(pixelsPerPoint ?? 2),
                                       settleTimeout: settleTimeout,
                                       sceneDate: sceneDate ?? Self.defaultSceneDate)
    }

    static func load(from url: URL) throws -> [Frame] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Frame].self, from: Data(contentsOf: url))
    }
}

/// The palettes a frame may be drawn in: the engine's default, and the
/// night palette of the settings example (`Examples/macOS/ImmersiveMapSettingsMac`),
/// copied here so the frame of the dark map is made from the same colours
/// the example shows.
enum Palette: String, Decodable {
    case day
    case night

    var theme: ProtomapsBasemapTheme {
        switch self {
        case .day:
            return .default
        case .night:
            return ProtomapsBasemapTheme.default
                .layers { layers in
                    layers.land = SIMD4<Float>(0.09, 0.10, 0.13, 1)
                    layers.water = SIMD4<Float>(0.04, 0.09, 0.20, 1)
                    layers.wood = SIMD4<Float>(0.06, 0.14, 0.11, 1)
                    layers.grass = SIMD4<Float>(0.08, 0.16, 0.12, 1)
                    layers.farmland = SIMD4<Float>(0.10, 0.14, 0.10, 1)
                    layers.wetland = SIMD4<Float>(0.07, 0.14, 0.13, 1)
                    layers.sand = SIMD4<Float>(0.16, 0.15, 0.13, 1)
                    layers.ice = SIMD4<Float>(0.30, 0.32, 0.36, 1)
                    layers.park = SIMD4<Float>(0.08, 0.17, 0.13, 1)
                    layers.residential = SIMD4<Float>(0.12, 0.12, 0.15, 1)
                    layers.industrial = SIMD4<Float>(0.14, 0.13, 0.15, 1)
                    layers.aeroway = SIMD4<Float>(0.16, 0.16, 0.19, 1)
                    layers.boundary = SIMD4<Float>(0.58, 0.36, 0.78, 0.9)
                    let base = SIMD4<Float>(0.42, 0.40, 0.36, 1)
                    let minor = SIMD4<Float>(0.24, 0.24, 0.28, 1)
                    layers.roads = ProtomapsBasemapTheme.RoadLayerStyles(motorway: base, trunk: base, primary: base,
                                                                         secondary: minor, tertiary: minor, minor: minor,
                                                                         service: minor, path: minor, rail: minor,
                                                                         casing: SIMD4<Float>(0.06, 0.06, 0.08, 0.95))
                }
                .features { features in
                    features.buildingFillColor = SIMD4<Float>(0.18, 0.19, 0.23, 1)
                }
                .labels { labels in
                    let fill = SIMD3<Float>(0.92, 0.94, 1.0)
                    let stroke = SIMD3<Float>(0.02, 0.03, 0.06)
                    labels.city.fillColor = fill; labels.city.strokeColor = stroke
                    labels.town.fillColor = fill; labels.town.strokeColor = stroke
                    labels.country.fillColor = fill; labels.country.strokeColor = stroke
                    labels.poi.fillColor = fill; labels.poi.strokeColor = stroke
                    labels.water.fillColor = SIMD3<Float>(0.55, 0.72, 0.96); labels.water.strokeColor = stroke
                    labels.road.fillColor = fill; labels.road.strokeColor = stroke
                }
        }
    }
}

/// The gallery in the README: the rows between the markers, written from
/// the frame list in its order. A `full` frame is a row of its own at the
/// page's width, the `half` frames stand two to a row, at 49% each, as the
/// README laid them out by hand before. A half left alone at the end of a
/// run of halves keeps its width, so a frame added later pairs with it.
enum Gallery {
    static let startMarker = "<!-- gallery:start -->"
    static let endMarker = "<!-- gallery:end -->"

    static func write(frames: [Frame], readme: URL, assets: URL) throws {
        let readmeText = try String(contentsOf: readme, encoding: .utf8)
        guard let start = readmeText.range(of: startMarker),
              let end = readmeText.range(of: endMarker, range: start.upperBound ..< readmeText.endIndex) else {
            throw ToolError("\(readme.path) has no gallery markers (\(startMarker) and \(endMarker)), so there is nowhere to write the gallery")
        }
        let assetsFolder = assets.lastPathComponent
        var missing: [String] = []
        for frame in frames where FileManager.default.fileExists(atPath: assets.appendingPathComponent("\(frame.name).png").path) == false {
            missing.append(frame.name)
        }
        guard missing.isEmpty else {
            throw ToolError("No picture for \(missing.joined(separator: ", ")) in \(assets.path): give the frame a camera and render it, or put the PNG there")
        }
        let rows = Self.rows(frames: frames)
        var block = "\n<!-- Written by Tools/ReadmeFrames from frames.json: edit the frames, not these rows. -->\n"
        for row in rows {
            block += "<p align=\"center\">\n"
            for frame in row {
                let width = frame.layout == .full ? "100%" : "49%"
                block += "  <img src=\"\(assetsFolder)/\(frame.name).png\" width=\"\(width)\" alt=\"\(escape(frame.alt ?? frame.name))\">\n"
            }
            block += "</p>\n"
        }
        let updated = readmeText.replacingCharacters(in: start.upperBound ..< end.lowerBound, with: block)
        try updated.write(to: readme, atomically: true, encoding: .utf8)
    }

    static func rows(frames: [Frame]) -> [[Frame]] {
        var rows: [[Frame]] = []
        var pair: [Frame] = []
        for frame in frames {
            if frame.layout == .full {
                if pair.isEmpty == false { rows.append(pair); pair = [] }
                rows.append([frame])
            } else {
                pair.append(frame)
                if pair.count == 2 { rows.append(pair); pair = [] }
            }
        }
        if pair.isEmpty == false { rows.append(pair) }
        return rows
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The command line: `--frames <json>` (Tools/ReadmeFrames/frames.json by
/// default), `--out <dir>` (Assets by default), `--readme <file>`
/// (README.md by default), `--only <name>` (renders that frame alone and
/// leaves the gallery as it is), `--gallery-only` (writes the gallery from
/// the pictures already there, rendering nothing) and `--settle <seconds>`
/// (60 by default, how long a frame waits for its tiles).
struct Options {
    var framesURL = ReadmeFrames.repositoryRoot.appendingPathComponent("Tools/ReadmeFrames/frames.json")
    var outputDirectory = ReadmeFrames.repositoryRoot.appendingPathComponent("Assets")
    var readmeURL = ReadmeFrames.repositoryRoot.appendingPathComponent("README.md")
    var only: String?
    var galleryOnly = false
    var settleTimeout: TimeInterval = 60

    init(arguments: [String]) throws {
        var arguments = arguments[...]
        func value(for flag: String) throws -> String {
            guard let next = arguments.popFirst() else {
                throw ToolError("\(flag) needs a value")
            }
            return next
        }
        while let argument = arguments.popFirst() {
            switch argument {
            case "--frames": framesURL = URL(fileURLWithPath: try value(for: argument))
            case "--out": outputDirectory = URL(fileURLWithPath: try value(for: argument))
            case "--readme": readmeURL = URL(fileURLWithPath: try value(for: argument))
            case "--only": only = try value(for: argument)
            case "--gallery-only": galleryOnly = true
            case "--settle":
                guard let seconds = TimeInterval(try value(for: argument)), seconds >= 0 else {
                    throw ToolError("--settle needs a number of seconds")
                }
                settleTimeout = seconds
            default:
                throw ToolError("Unknown argument \(argument). Options: --frames <json>, --out <dir>, --readme <file>, --only <name>, --gallery-only, --settle <seconds>")
            }
        }
    }
}

struct ToolError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
