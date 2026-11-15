// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// What an app registered under a source's name
/// (`ImmersiveMapLayersController.register`). Each kind states what it is
/// without being read: a file by where it is, data handed over in memory
/// by the identity the app gives it. Nothing here is hashed. Two
/// registrations are the same data when they state the same, so a view
/// that registers its sources on every update reads nothing twice, and a
/// layer prepared in an earlier launch is found again on disk
/// (`LayerMeshDiskCache`).
enum LayerSourceData: Equatable, Sendable {
    /// A GeoJSON document in a file, read when its shapes are needed.
    case geoJSONFile(URL)
    /// A GeoJSON document in memory, read when its shapes are needed.
    case geoJSON(Data, identity: String)
    /// Shapes built in code.
    case shapes(polygons: [ImmersiveMapPolygon],
                polylines: [ImmersiveMapPolyline],
                points: [ImmersiveMapPoint],
                identity: String)

    /// What the data is told apart by, on disk and between registrations.
    var identity: LayerSourceIdentity {
        switch self {
        case .geoJSONFile(let url): return .file(url)
        case .geoJSON(_, let identity), .shapes(_, _, _, let identity): return .named(identity)
        }
    }

    static func == (lhs: LayerSourceData, rhs: LayerSourceData) -> Bool {
        switch (lhs, rhs) {
        case (.geoJSONFile, .geoJSONFile), (.geoJSON, .geoJSON), (.shapes, .shapes):
            return lhs.identity == rhs.identity
        default:
            return false
        }
    }
}

/// What a source's data is told apart by.
enum LayerSourceIdentity: Equatable, Sendable {
    /// A file: the file itself, as it is on disk (its path, size and
    /// modification date).
    case file(URL)
    /// Data handed over in memory: the identity the app gave it.
    case named(String)
}

/// The shapes of a source, read and ready to be drawn: shared by every
/// layer that draws the source and by every map that draws those layers.
/// Every shape has an id here: its own, or its place among the source's
/// shapes, the zones counted first, then the lines, then the points.
/// Immutable.
final class LayerSourceContent: Sendable {
    let polygons: [ImmersiveMapPolygon]
    let polylines: [ImmersiveMapPolyline]
    let points: [ImmersiveMapPoint]
    /// The memory the shapes take, what the input limit counts
    /// (`ImmersiveMapLayersController.inputLimitBytes`): every coordinate
    /// and a fixed cost for each shape.
    let byteSize: Int

    init(polygons: [ImmersiveMapPolygon], polylines: [ImmersiveMapPolyline], points: [ImmersiveMapPoint]) {
        var polygons = polygons
        var polylines = polylines
        var points = points
        for index in polygons.indices where polygons[index].id == nil {
            polygons[index].id = UInt64(index)
        }
        for index in polylines.indices where polylines[index].id == nil {
            polylines[index].id = UInt64(polygons.count + index)
        }
        for index in points.indices where points[index].id == nil {
            points[index].id = UInt64(polygons.count + polylines.count + index)
        }
        self.polygons = polygons
        self.polylines = polylines
        self.points = points
        let coordinateSize = MemoryLayout<GeoCoordinate>.stride
        var size = polygons.count * MemoryLayout<ImmersiveMapPolygon>.stride
            + polylines.count * MemoryLayout<ImmersiveMapPolyline>.stride
            + points.count * MemoryLayout<ImmersiveMapPoint>.stride
        for polygon in polygons {
            size += polygon.exterior.count * coordinateSize
            for hole in polygon.holes {
                size += hole.count * coordinateSize
            }
        }
        for polyline in polylines {
            size += polyline.coordinates.count * coordinateSize
        }
        byteSize = size
    }

    /// Reads what was registered. Throws `ImmersiveMapLayerSourceError`.
    static func load(_ data: LayerSourceData) throws -> LayerSourceContent {
        let shapes: ImmersiveMapGeoJSON.Shapes
        switch data {
        case .geoJSONFile(let url):
            let bytes: Data
            do {
                bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                throw ImmersiveMapLayerSourceError.unreadableFile(error.localizedDescription)
            }
            shapes = try decode(bytes)
        case .geoJSON(let bytes, _):
            shapes = try decode(bytes)
        case .shapes(let polygons, let polylines, let points, _):
            return LayerSourceContent(polygons: polygons, polylines: polylines, points: points)
        }
        return LayerSourceContent(polygons: shapes.polygons, polylines: shapes.polylines, points: shapes.points)
    }

    private static func decode(_ bytes: Data) throws -> ImmersiveMapGeoJSON.Shapes {
        do {
            return try ImmersiveMapGeoJSON.decode(bytes)
        } catch let error as ImmersiveMapGeoJSONError {
            throw ImmersiveMapLayerSourceError.invalidGeoJSON(error)
        }
    }
}

/// Why a registered source cannot be drawn
/// (`ImmersiveMapLayersController.onSourceFailed`).
public enum ImmersiveMapLayerSourceError: Error, Equatable, Sendable {
    /// The file could not be read, for the reason given.
    case unreadableFile(String)
    /// The document is not GeoJSON.
    case invalidGeoJSON(ImmersiveMapGeoJSONError)
    /// The source's shapes take `bytes`, and with the other sources being
    /// drawn that is over the controller's input limit of `limit` bytes.
    /// The source is read again when one of the others stops being drawn.
    case limitExceeded(bytes: Int, limit: Int)
}
