// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A FeatureCollection: every object of its `features`, in order.
struct GeoJSONFeatureCollectionReader: GeoJSONObjectReader {
    let type = "FeatureCollection"

    func read(_ object: [String: Any],
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        guard let features = object["features"] as? [Any] else {
            throw ImmersiveMapGeoJSONError.invalidCoordinates("\(path)features")
        }
        for (index, feature) in features.enumerated() {
            try context.read(object: feature, style: style, path: "\(path)features[\(index)].")
        }
    }
}

/// A Feature: its geometry, under the simplestyle its properties state. A
/// feature with no geometry, or a null one, is skipped.
struct GeoJSONFeatureReader: GeoJSONObjectReader {
    let type = "Feature"

    func read(_ object: [String: Any],
              style _: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let properties = object["properties"] as? [String: Any] ?? [:]
        let featureStyle = ImmersiveMapGeoJSON.simpleStyle(of: properties)
        guard let geometry = object["geometry"], (geometry is NSNull) == false else { return }
        try context.read(object: geometry, style: featureStyle, path: "\(path)geometry.")
    }
}

/// A GeometryCollection: every object of its `geometries`, in order.
struct GeoJSONGeometryCollectionReader: GeoJSONObjectReader {
    let type = "GeometryCollection"

    func read(_ object: [String: Any],
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        guard let geometries = object["geometries"] as? [Any] else {
            throw ImmersiveMapGeoJSONError.invalidCoordinates("\(path)geometries")
        }
        for (index, geometry) in geometries.enumerated() {
            try context.read(object: geometry, style: style, path: "\(path)geometries[\(index)].")
        }
    }
}
