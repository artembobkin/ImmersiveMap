// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Reads one kind of GeoJSON object, the one whose `type` member is
/// `type`: a container descends into its members through the context, a
/// geometry adds its shapes to it. A new kind of object is a new
/// conformance listed in `GeoJSONObjectReaders.all`, and nothing else
/// changes.
protocol GeoJSONObjectReader: Sendable {
    /// The value of the object's `type` member.
    var type: String { get }

    /// Reads `object`, which lies at `path` (the members from the
    /// document's root, ending in a dot unless empty), under `style`, the
    /// simplestyle of the feature it belongs to.
    func read(_ object: [String: Any],
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws
}

/// Reads a geometry: an object whose shapes are in its `coordinates`.
protocol GeoJSONGeometryReader: GeoJSONObjectReader {
    /// Reads the geometry's `coordinates`, which lie at `path`.
    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws
}

extension GeoJSONGeometryReader {
    func read(_ object: [String: Any],
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let coordinatesPath = "\(path)coordinates"
        guard let coordinates = object["coordinates"] else {
            throw ImmersiveMapGeoJSONError.invalidCoordinates(coordinatesPath)
        }
        try read(coordinates: coordinates, style: style, path: coordinatesPath, into: &context)
    }
}

/// Every kind of object a document may hold, found by its `type`.
enum GeoJSONObjectReaders {
    static let all: [any GeoJSONObjectReader] = [
        GeoJSONFeatureCollectionReader(),
        GeoJSONFeatureReader(),
        GeoJSONGeometryCollectionReader(),
        GeoJSONPointReader(),
        GeoJSONMultiPointReader(),
        GeoJSONLineStringReader(),
        GeoJSONMultiLineStringReader(),
        GeoJSONPolygonReader(),
        GeoJSONMultiPolygonReader()
    ]

    static let byType: [String: any GeoJSONObjectReader] = Dictionary(uniqueKeysWithValues: all.map { ($0.type, $0) })
}

/// What a document is read into: the shapes found so far and the layer's
/// styles they are laid over. A reader that holds other objects hands each
/// one back to `read(object:style:path:)`, which finds its reader.
struct GeoJSONReadContext {
    let base: ImmersiveMapGeoJSON.BaseStyles
    var shapes = ImmersiveMapGeoJSON.Shapes()

    init(base: ImmersiveMapGeoJSON.BaseStyles) {
        self.base = base
    }

    mutating func read(object: Any, style: ImmersiveMapGeoJSON.SimpleStyle, path: String) throws {
        guard let dictionary = object as? [String: Any], let type = dictionary["type"] as? String else {
            throw ImmersiveMapGeoJSONError.unknownType(path.isEmpty ? "root" : path)
        }
        guard let reader = GeoJSONObjectReaders.byType[type] else {
            throw ImmersiveMapGeoJSONError.unknownType(type)
        }
        try reader.read(dictionary, style: style, path: path, into: &self)
    }
}
