// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public struct ImmersiveMapTerrainSource: Equatable {
    public enum Encoding: String, Equatable {
        case mapboxTerrainRGB
        case terrarium
    }

    public enum Datum: String, Equatable {
        case elevation
        case ellipsoid
        case geoid
    }

    public var id: String
    public var baseURL: URL
    public var encoding: Encoding
    public var datum: Datum
    public var maximumZoomLevel: Int

    public init(id: String,
                baseURL: URL,
                encoding: Encoding,
                datum: Datum,
                maximumZoomLevel: Int) {
        self.id = id
        self.baseURL = baseURL
        self.encoding = encoding
        self.datum = datum
        self.maximumZoomLevel = maximumZoomLevel
    }

    public static func reEarth(baseURL: URL = URL(string: "https://terrain.reearth.land")!,
                               encoding: Encoding = .mapboxTerrainRGB,
                               datum: Datum = .elevation,
                               maximumZoomLevel: Int = 14) -> ImmersiveMapTerrainSource {
        ImmersiveMapTerrainSource(id: "reearth-\(encoding.rawValue)-\(datum.rawValue)",
                                  baseURL: baseURL,
                                  encoding: encoding,
                                  datum: datum,
                                  maximumZoomLevel: maximumZoomLevel)
    }
}
