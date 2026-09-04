// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt

// The tile-space geometry the decoder produces, under the names the parser
// has always used. Declared here so the engine's own declarations shadow the
// same names that ApplicationServices (QuickDraw's `Point` and `Polygon`)
// exports into every file that imports AppKit or Metal on macOS; an imported
// `Mvt.Polygon` alone would be ambiguous there.
typealias Point = Mvt.Point
typealias Polygon = Mvt.Polygon
typealias MultiPolygon = Mvt.MultiPolygon
typealias LineString = Mvt.LineString
typealias MultiLineString = Mvt.MultiLineString
typealias MultiPoint = Mvt.MultiPoint
