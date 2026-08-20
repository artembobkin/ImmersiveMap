// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

extension TileMvtParser {
    struct BuildingExtrusionCandidate {
        let styleKey: UInt8
        let buildingId: UInt64
        let footprintSignature: BuildingFootprintSignature
        let clippedExterior: [SIMD2<Float>]
        let clippedInteriors: [[SIMD2<Float>]]
        /// The exterior ring as the tile carries it, before the clip to the
        /// tile square, in the same converted coordinates as `clippedExterior`.
        /// The roof frame must come from this whole footprint, never from the
        /// clipped one, or ridges break at tile edges.
        let rawExterior: [SIMD2<Float>]
        let hasRawInteriorRings: Bool
        let roof: ParsedPolygon
        let roofInfo: RoofInfo?
        let baseHeight: Float
        let topHeight: Float
    }

    struct BuildingFootprintSignature: Hashable {
        let exterior: [UInt64]
        let interiors: [[UInt64]]
    }

    static func makePointLabelKey(text: String,
                                  anchor: SIMD2<Int16>,
                                  featureId: UInt64,
                                  hasFeatureId: Bool,
                                  layerName: String) -> UInt64 {
        if hasFeatureId {
            return makeLayerFeatureLabelKey(featureId: featureId, layerName: layerName)
        }
        return makeFallbackLabelKey(text: text,
                                    geometryHash: makePointAnchorHash(anchor),
                                    layerName: layerName)
    }

    static func makeRoadLabelKey(text: String,
                                 path: [SIMD2<Int16>],
                                 featureId: UInt64,
                                 hasFeatureId: Bool,
                                 layerName: String) -> UInt64 {
        if hasFeatureId {
            return makeLayerFeatureLabelKey(featureId: featureId, layerName: layerName)
        }
        return makeFallbackLabelKey(text: text,
                                    geometryHash: makeRoadPathHash(path),
                                    layerName: layerName)
    }

    private static func makeLayerFeatureLabelKey(featureId: UInt64, layerName: String) -> UInt64 {
        var hash = labelKeySeed
        mixUtf8(into: &hash, string: layerName)
        mix(into: &hash, value: featureId)
        return hash
    }

    private static func makeFallbackLabelKey(text: String,
                                             geometryHash: UInt64,
                                             layerName: String) -> UInt64 {
        var hash = labelKeySeed
        mixUtf8(into: &hash, string: layerName)
        mixUtf8(into: &hash, string: text)
        mix(into: &hash, value: geometryHash)
        return hash
    }

    private static func makePointAnchorHash(_ anchor: SIMD2<Int16>) -> UInt64 {
        var hash = labelKeySeed
        mix(into: &hash, value: packedInt16Pair(anchor))
        return hash
    }

    private static func makeRoadPathHash(_ path: [SIMD2<Int16>]) -> UInt64 {
        var hash = labelKeySeed
        mix(into: &hash, value: UInt64(path.count))
        for point in path {
            mix(into: &hash, value: packedInt16Pair(point))
        }
        return hash
    }

    private static func mixUtf8(into hash: inout UInt64, string: String) {
        for byte in string.utf8 {
            mix(into: &hash, value: UInt64(byte))
        }
    }

    private static func mix(into hash: inout UInt64, value: UInt64) {
        hash ^= value
        hash &*= labelKeyPrime
    }

    private static func packedInt16Pair(_ point: SIMD2<Int16>) -> UInt64 {
        let x = UInt32(UInt16(bitPattern: point.x))
        let y = UInt32(UInt16(bitPattern: point.y))
        let packed = (x << 16) | y
        return UInt64(packed)
    }

    private static let labelKeySeed: UInt64 = 1469598103934665603
    private static let labelKeyPrime: UInt64 = 1099511628211

    func decodeAttributes(feature: MvtDecodedFeature,
                          layer: MvtDecodedLayer,
                          data: Data) -> [String: VectorTile_Tile.Value] {
        data.withUnsafeBytes { bytes in
            decodeAttributes(feature: feature, layer: layer, bytes: bytes)
        }
    }

    func decodeAttributes(feature: MvtDecodedFeature,
                          layer: MvtDecodedLayer,
                          bytes: UnsafeRawBufferPointer) -> [String: VectorTile_Tile.Value] {
        var attributes: [String: VectorTile_Tile.Value] = [:]
        switch feature.tags {
        case .empty:
            break
        case .range(let range):
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else { break }
            var reader = MvtVarintUInt32Reader(bytes: bytes, range: range)
            appendAttributes(reader: &reader, layer: layer, into: &attributes)
        case .values(let values):
            var reader = MvtArrayUInt32Reader(values: values)
            appendAttributes(reader: &reader, layer: layer, into: &attributes)
        }
        return attributes
    }

    private func appendAttributes<Reader: MvtUInt32Reading>(reader: inout Reader,
                                                            layer: MvtDecodedLayer,
                                                            into attributes: inout [String: VectorTile_Tile.Value]) {
        while let keyIndex = reader.next() {
            guard let valueIndex = reader.next() else { break }

            guard Int(keyIndex) < layer.keys.count,
                  Int(valueIndex) < layer.values.count else { continue }

            attributes[layer.keys[Int(keyIndex)]] = layer.values[Int(valueIndex)]
        }
    }

    func parseBoolValue(_ value: VectorTile_Tile.Value) -> Bool? {
        if value.hasBoolValue {
            return value.boolValue
        }
        if value.hasUintValue {
            return value.uintValue != 0
        }
        if value.hasSintValue {
            return value.sintValue != 0
        }
        if value.hasIntValue {
            return value.intValue != 0
        }
        if value.hasFloatValue {
            return value.floatValue != 0
        }
        if value.hasDoubleValue {
            return value.doubleValue != 0
        }
        if value.hasStringValue {
            let lower = value.stringValue.lowercased()
            if lower == "true" || lower == "yes" || lower == "1" {
                return true
            }
            if lower == "false" || lower == "no" || lower == "0" {
                return false
            }
        }
        return nil
    }

    func parseUInt64Value(_ value: VectorTile_Tile.Value) -> UInt64? {
        if value.hasUintValue {
            return value.uintValue
        }
        if value.hasSintValue {
            return value.sintValue >= 0 ? UInt64(value.sintValue) : nil
        }
        if value.hasIntValue {
            return value.intValue >= 0 ? UInt64(value.intValue) : nil
        }
        if value.hasStringValue {
            return UInt64(value.stringValue)
        }
        return nil
    }

    func parseIntValue(_ value: VectorTile_Tile.Value) -> Int? {
        if value.hasIntValue {
            return Int(value.intValue)
        }
        if value.hasSintValue {
            return Int(value.sintValue)
        }
        if value.hasUintValue {
            guard value.uintValue <= UInt64(Int.max) else { return nil }
            return Int(value.uintValue)
        }
        if value.hasFloatValue {
            return Int(value.floatValue)
        }
        if value.hasDoubleValue {
            return Int(value.doubleValue)
        }
        if value.hasStringValue {
            return Int(value.stringValue)
        }
        return nil
    }

    func isTruthy(_ value: VectorTile_Tile.Value?) -> Bool {
        guard let value = value else { return false }
        return parseBoolValue(value) ?? false
    }

    func appendComplexOceanPolygon(_ polygon: Polygon,
                                   style: FeatureStyle,
                                   polygonByStyle: inout [UInt8: [ParsedPolygon]],
                                   styles: inout [UInt8: FeatureStyle],
                                   parsePolygon: ParsePolygon,
                                   tile: Tile) -> Bool {
        guard polygon.interiorRings.count >= Self.complexOceanHoleSplitThreshold else {
            return false
        }

        let oceanPolygon = Polygon(exteriorRing: polygon.exteriorRing,
                                   interiorRings: [])
        guard let parsedOcean = parsePolygon.parse(polygon: oceanPolygon,
                                                   tileExtent: Float(tileExtent)) else {
            return false
        }

        polygonByStyle[style.key, default: []].append(parsedOcean)
        styles[style.key] = style

        let landStyle = determineFeatureStyle.makeStyle(data: DetFeatureStyleData(layerName: "background",
                                                                                  properties: [:],
                                                                                  tile: tile))
        guard landStyle.key != 0 else {
            return true
        }

        styles[landStyle.key] = landStyle
        for interiorRing in polygon.interiorRings {
            let landPolygon = Polygon(exteriorRing: interiorRing,
                                      interiorRings: [])
            if let parsedLand = parsePolygon.parse(polygon: landPolygon,
                                                   tileExtent: Float(tileExtent)) {
                polygonByStyle[landStyle.key, default: []].append(parsedLand)
            }
        }
        return true
    }

    func buildingIdentifier(attributes: [String: VectorTile_Tile.Value],
                            featureId: UInt64) -> UInt64 {
        if let value = attributes["osm_id"], let id = parseUInt64Value(value) {
            return id
        }
        if let value = attributes["id"], let id = parseUInt64Value(value) {
            return id
        }
        if let value = attributes["building_id"], let id = parseUInt64Value(value) {
            return id
        }
        return featureId
    }

    /// One pass over a building layer collecting both the part identifiers and
    /// the part footprint signatures, from attributes the caller already
    /// decoded.
    func collectBuildingPartInfo(layer: MvtDecodedLayer,
                                 featureAttributes: [[String: VectorTile_Tile.Value]],
                                 data: Data)
        -> (partIds: Set<UInt64>, footprintSignatures: Set<BuildingFootprintSignature>) {
        var partIds = Set<UInt64>()
        var signatures = Set<BuildingFootprintSignature>()
        for (featureIndex, feature) in layer.features.enumerated() {
            let attributes = featureAttributes[featureIndex]
            guard isTruthy(attributes["building:part"]) else { continue }
            partIds.insert(buildingIdentifier(attributes: attributes, featureId: feature.id))
            let polygons = normalize(MvtGeometryDecoder.decodePolygons(feature.geometry, in: data), layer: layer)
            for polygon in polygons {
                if let signature = buildingFootprintSignature(for: polygon) {
                    signatures.insert(signature)
                }
            }
        }
        return (partIds, signatures)
    }

    func normalize(_ polygons: MultiPolygon, layer: MvtDecodedLayer) -> MultiPolygon {
        let scale = coordinateScale(for: layer)
        guard scale != 1 else {
            return polygons
        }
        return polygons.map { polygon in
            Polygon(exteriorRing: normalize(polygon.exteriorRing, scale: scale),
                    interiorRings: polygon.interiorRings.map { normalize($0, scale: scale) })
        }
    }

    func normalize(_ lines: MultiLineString, layer: MvtDecodedLayer) -> MultiLineString {
        let scale = coordinateScale(for: layer)
        guard scale != 1 else {
            return lines
        }
        return lines.map { normalize($0, scale: scale) }
    }

    func normalize(_ points: MultiPoint, layer: MvtDecodedLayer) -> MultiPoint {
        let scale = coordinateScale(for: layer)
        guard scale != 1 else {
            return points
        }
        return normalize(points, scale: scale)
    }

    private func coordinateScale(for layer: MvtDecodedLayer) -> Double {
        guard layer.extent > 0 else {
            return 1
        }
        return tileExtent / Double(layer.extent)
    }

    private func normalize(_ points: [Point], scale: Double) -> [Point] {
        points.map { point in
            Point(x: Int32((Double(point.x) * scale).rounded()),
                  y: Int32((Double(point.y) * scale).rounded()))
        }
    }

    func buildingFootprintSignature(for polygon: Polygon) -> BuildingFootprintSignature? {
        guard let exterior = canonicalRingSignature(polygon.exteriorRing) else {
            return nil
        }

        let interiors = polygon.interiorRings.compactMap(canonicalRingSignature).sorted(by: lexicographicallyLess)
        return BuildingFootprintSignature(exterior: exterior, interiors: interiors)
    }

    private func canonicalRingSignature(_ ring: [Point]) -> [UInt64]? {
        let sanitized = sanitizeBuildingRing(ring)
        guard sanitized.count >= 3 else {
            return nil
        }

        let forward = sanitized.map(packFootprintPoint)
        let backward = Array(forward.reversed())
        let forwardCandidate = canonicalRotation(forward)
        let backwardCandidate = canonicalRotation(backward)
        return lexicographicallyLess(forwardCandidate, backwardCandidate) ? forwardCandidate : backwardCandidate
    }

    private func sanitizeBuildingRing(_ ring: [Point]) -> [Point] {
        guard ring.isEmpty == false else { return [] }

        var ringPoints = ring
        if let last = ringPoints.last,
           let first = ringPoints.first,
           last.x == first.x,
           last.y == first.y {
            ringPoints.removeLast()
        }

        var filtered: [Point] = []
        filtered.reserveCapacity(ringPoints.count)
        for point in ringPoints {
            if let last = filtered.last,
               last.x == point.x,
               last.y == point.y {
                continue
            }
            if filtered.count >= 2 {
                let beforeLast = filtered[filtered.count - 2]
                if beforeLast.x == point.x, beforeLast.y == point.y {
                    filtered.removeLast()
                    continue
                }
            }
            filtered.append(point)
        }

        if let last = filtered.last,
           let first = filtered.first,
           last.x == first.x,
           last.y == first.y {
            filtered.removeLast()
        }
        return filtered
    }

    private func packFootprintPoint(_ point: Point) -> UInt64 {
        let x = UInt32(bitPattern: point.x)
        let y = UInt32(bitPattern: point.y)
        return (UInt64(x) << 32) | UInt64(y)
    }

    private func canonicalRotation(_ values: [UInt64]) -> [UInt64] {
        guard values.count > 1 else { return values }

        var best = values
        for start in 1..<values.count {
            var candidate: [UInt64] = []
            candidate.reserveCapacity(values.count)
            candidate.append(contentsOf: values[start...])
            candidate.append(contentsOf: values[..<start])
            if lexicographicallyLess(candidate, best) {
                best = candidate
            }
        }
        return best
    }

    private func lexicographicallyLess(_ lhs: [UInt64], _ rhs: [UInt64]) -> Bool {
        let count = min(lhs.count, rhs.count)
        for index in 0..<count {
            if lhs[index] != rhs[index] {
                return lhs[index] < rhs[index]
            }
        }
        return lhs.count < rhs.count
    }

    struct ExtrusionHeights {
        let base: Float
        let top: Float
        let roof: RoofInfo?
    }

    func extrusionHeights(attributes: [String: VectorTile_Tile.Value], tileZoom: Int, style: FeatureStyle) -> ExtrusionHeights? {
        // `height`/`min_height` are the Mapbox convention; `render_height`/
        // `render_min_height` are the OpenMapTiles convention. Accept either.
        let rawHeight = attributes["height"].flatMap(parseNumericValue)
            ?? attributes["render_height"].flatMap(parseNumericValue)
        let rawMinHeight = attributes["min_height"].flatMap(parseNumericValue)
            ?? attributes["render_min_height"].flatMap(parseNumericValue)
        let levelHeight: Float = 3.2
        let rawLevels = attributes["building:levels"].flatMap(parseNumericValue)
            ?? attributes["levels"].flatMap(parseNumericValue)
        let rawMinLevels = attributes["building:min_level"].flatMap(parseNumericValue)
            ?? attributes["min_level"].flatMap(parseNumericValue)
        let levelHeightValue = rawLevels.map { $0 * levelHeight }
        let minLevelHeightValue = rawMinLevels.map { $0 * levelHeight }
        let fallbackHeight = style.extrusionFallbackHeight

        if rawHeight == nil && rawMinHeight == nil && levelHeightValue == nil {
            guard fallbackHeight > 0 else { return nil }
        }

        let resolvedHeight = rawHeight ?? levelHeightValue ?? fallbackHeight
        guard resolvedHeight > 0 else { return nil }
        let resolvedMinHeight = rawMinHeight ?? minLevelHeightValue ?? 0

        let zoomDelta = tileZoom - style.extrusionAnchorZoom
        let zoomScale = powf(2.0, Float(zoomDelta))
        let scaledHeight = resolvedHeight * style.extrusionHeightScale * zoomScale
        let scaledMinHeight = resolvedMinHeight * style.extrusionHeightScale * zoomScale

        let base = max(0, min(scaledMinHeight, scaledHeight))
        let top = max(scaledHeight, base)
        let roofParser = RoofAttributesParser()
        let roofInfo = roofParser.parse(attributes: attributes, numericParser: parseNumericValue)
        let scaledRoof = roofInfo.map {
            RoofInfo(height: $0.height * style.extrusionHeightScale * zoomScale,
                     shape: $0.shape,
                     orientation: $0.orientation,
                     directionDegrees: $0.directionDegrees)
        }
        return ExtrusionHeights(base: base, top: top, roof: scaledRoof)
    }

    func parseNumericValue(_ value: VectorTile_Tile.Value) -> Float? {
        if value.hasFloatValue {
            return value.floatValue
        }
        if value.hasDoubleValue {
            return Float(value.doubleValue)
        }
        if value.hasUintValue {
            return Float(value.uintValue)
        }
        if value.hasIntValue {
            return Float(value.intValue)
        }
        if value.hasSintValue {
            return Float(value.sintValue)
        }
        if value.hasStringValue {
            let raw = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let token = raw.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).first
            guard let token else { return nil }
            var numeric = ""
            var hasDigit = false
            for scalar in token.unicodeScalars {
                let ch = Character(scalar)
                if ch.isNumber {
                    numeric.append(ch)
                    hasDigit = true
                    continue
                }
                if (ch == "-" || ch == "+"), numeric.isEmpty {
                    numeric.append(ch)
                    continue
                }
                if ch == ".", numeric.contains(".") == false {
                    numeric.append(ch)
                    continue
                }
                break
            }
            guard hasDigit, let value = Float(numeric) else { return nil }
            if raw.contains("ft") || raw.contains("feet") {
                return value * 0.3048
            }
            return value
        }
        return nil
    }

    func buildExtrudedMesh(
        clippedExterior: [SIMD2<Float>],
        clippedInteriors: [[SIMD2<Float>]],
        rawExterior: [SIMD2<Float>] = [],
        hasRawInteriorRings: Bool = false,
        roof: ParsedPolygon,
        roofInfo: RoofInfo?,
        baseHeight: Float,
        topHeight: Float,
        tileExtent: Float
    ) -> ParsedExtrudedMesh? {
        guard topHeight > baseHeight else { return nil }
        
        var vertices: [ParsedExtrudedVertex] = []
        var indices: [UInt32] = []
        var nextLocalSurfaceID: UInt32 = 1
        
        let epsilon: Float = 0.001
        let extent = tileExtent
        func isOnBoundary(_ point: SIMD2<Float>) -> Bool {
            abs(point.x) <= epsilon ||
            abs(point.y) <= epsilon ||
            abs(point.x - extent) <= epsilon ||
            abs(point.y - extent) <= epsilon
        }

        func isBoundaryEdge(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
            guard isOnBoundary(a), isOnBoundary(b) else { return false }
            return abs(a.x - b.x) <= epsilon || abs(a.y - b.y) <= epsilon
        }

        func ringArea(_ ring: [SIMD2<Float>]) -> Float {
            guard ring.count >= 3 else { return 0 }
            var sum: Float = 0
            for i in 0..<ring.count {
                let j = (i + 1) % ring.count
                sum += ring[i].x * ring[j].y - ring[j].x * ring[i].y
            }
            return sum * 0.5
        }

        func sanitizeRing(_ ring: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var ringPoints = ring
            if let last = ringPoints.last, let first = ringPoints.first, last == first {
                ringPoints.removeLast()
            }

            var filteredRing: [SIMD2<Float>] = []
            filteredRing.reserveCapacity(ringPoints.count)
            for point in ringPoints {
                if filteredRing.last == point {
                    continue
                }
                if filteredRing.count >= 2, filteredRing[filteredRing.count - 2] == point {
                    filteredRing.removeLast()
                    continue
                }
                filteredRing.append(point)
            }
            if filteredRing.count >= 2, let last = filteredRing.last, let first = filteredRing.first, last == first {
                filteredRing.removeLast()
            }
            return filteredRing
        }

        func ensureWinding(_ ring: [SIMD2<Float>], clockwise: Bool) -> [SIMD2<Float>] {
            var ringPoints = ring
            let area = ringArea(ringPoints)
            let isClockwise = area < 0
            if isClockwise != clockwise {
                ringPoints.reverse()
            }
            return ringPoints
        }

        let sanitizedExterior = sanitizeRing(clippedExterior)
        let footprintRing = rawExterior.isEmpty ? sanitizedExterior : sanitizeRing(rawExterior)
        let hasInteriorRings = hasRawInteriorRings
            || clippedInteriors.contains { sanitizeRing($0).count >= 3 }
        let roofGeometry = roofInfo.flatMap {
            RoofGeometryBuilder.build(roof: $0,
                                      footprintRing: footprintRing,
                                      wallRing: sanitizedExterior,
                                      hasInteriorRings: hasInteriorRings,
                                      flatTriangulationVertices: roof.vertices.map {
                                          SIMD2<Float>(Float($0.x), Float($0.y))
                                      },
                                      flatTriangulationIndices: roof.indices,
                                      baseHeight: baseHeight,
                                      topHeight: topHeight,
                                      tileExtent: tileExtent)
        }
        let roofOffset = UInt32(vertices.count)
        if let roofGeometry {
            let roofSurfaceID = nextLocalSurfaceID
            nextLocalSurfaceID &+= 1
            vertices.append(contentsOf: roofGeometry.surfaceVertices.map {
                ParsedExtrudedVertex(position: $0.position, normal: $0.normal, surfaceID: roofSurfaceID)
            })
            indices.append(contentsOf: roofGeometry.surfaceIndices.map { $0 + roofOffset })
        } else if roof.indices.count >= 3 {
            // Flat tag, no roof tags, or a footprint the roof builder cannot
            // shape: a flat lid at the full height. A wrong roof reads worse
            // than a flat one.
            let roofSurfaceID = nextLocalSurfaceID
            nextLocalSurfaceID &+= 1
            let roofNormal = SIMD3<Float>(0, 0, 1)
            vertices.append(contentsOf: roof.vertices.map {
                ParsedExtrudedVertex(
                    position: SIMD3<Float>(Float($0.x), Float($0.y), topHeight),
                    normal: roofNormal,
                    surfaceID: roofSurfaceID
                )
            })
            for i in stride(from: 0, to: roof.indices.count, by: 3) {
                if i + 2 >= roof.indices.count { break }
                let i0 = roof.indices[i] + roofOffset
                let i1 = roof.indices[i + 1] + roofOffset
                let i2 = roof.indices[i + 2] + roofOffset
                indices.append(i0)
                indices.append(i2)
                indices.append(i1)
            }
        }

        let wallTop: (SIMD2<Float>) -> Float = roofGeometry?.wallTop ?? { _ in topHeight }

        func appendWalls(for ring: [SIMD2<Float>], clockwise: Bool, isSanitized: Bool = false) {
            var ringPoints = isSanitized ? ring : sanitizeRing(ring)
            guard ringPoints.count >= 2 else { return }
            ringPoints = ensureWinding(ringPoints, clockwise: clockwise)

            for i in 0..<ringPoints.count {
                let next = (i + 1) % ringPoints.count
                let p0 = ringPoints[i]
                let p1 = ringPoints[next]
                if p0 == p1 { continue }
                if isBoundaryEdge(p0, p1) { continue }

                let v0 = SIMD3<Float>(p0.x, p0.y, baseHeight)
                let v1 = SIMD3<Float>(p1.x, p1.y, baseHeight)
                let top0 = wallTop(p0)
                let top1 = wallTop(p1)
                let v2 = SIMD3<Float>(p1.x, p1.y, top1)
                let v3 = SIMD3<Float>(p0.x, p0.y, top0)
                // Argument order makes every wall normal face out of the
                // building material: away from an exterior ring's interior,
                // into a hole ring's cavity (exterior rings are wound CW
                // here, holes CCW). The shading contract depends on this:
                // the shadow shader treats an away-facing normal as
                // geometric self-shadow.
                let wallNormal = simd_normalize(simd_cross(v2 - v0, v1 - v0))
                if wallNormal.x.isNaN || wallNormal.y.isNaN || wallNormal.z.isNaN {
                    continue
                }

                let wallSurfaceID = nextLocalSurfaceID
                nextLocalSurfaceID &+= 1
                let startIndex = UInt32(vertices.count)
                vertices.append(ParsedExtrudedVertex(position: v0, normal: wallNormal, surfaceID: wallSurfaceID))
                vertices.append(ParsedExtrudedVertex(position: v1, normal: wallNormal, surfaceID: wallSurfaceID))
                vertices.append(ParsedExtrudedVertex(position: v2, normal: wallNormal, surfaceID: wallSurfaceID))
                vertices.append(ParsedExtrudedVertex(position: v3, normal: wallNormal, surfaceID: wallSurfaceID))

                indices.append(contentsOf: [
                    startIndex, startIndex + 1, startIndex + 2,
                    startIndex, startIndex + 2, startIndex + 3
                ])
            }
        }

        // Exterior: CW so walls are front-facing with back culling in current tile space.
        // The roof geometry's ring carries extra vertices where the gable ridge
        // crosses an edge, so wall tops can follow the roof up to the ridge.
        appendWalls(for: roofGeometry?.wallExteriorRing ?? sanitizedExterior, clockwise: true, isSanitized: true)
        for interior in clippedInteriors {
            // Interior (hole): opposite winding
            appendWalls(for: interior, clockwise: false)
        }
        
        return indices.isEmpty ? nil : ParsedExtrudedMesh(vertices: vertices, indices: indices)
    }

    /// Wraps a candidate with its footprint bbox and area, both computed exactly
    /// once. The passes below compare O(n^2) candidate pairs; recomputing these
    /// per pair (instead of per candidate) used to dominate tile-parse CPU time.
    private struct MeasuredBuildingExtrusionCandidate {
        let candidate: BuildingExtrusionCandidate
        let bounds: FootprintBounds
        let area: Float
    }

    func resolveExteriorBuildingExtrusions(_ candidates: [BuildingExtrusionCandidate]) -> [BuildingExtrusionCandidate] {
        guard candidates.count > 1 else { return candidates }

        let measuredCandidates = candidates.map { candidate in
            MeasuredBuildingExtrusionCandidate(candidate: candidate,
                                               bounds: footprintBounds(candidate.clippedExterior),
                                               area: polygonAreaMagnitude(candidate.clippedExterior))
        }

        var filtered: [MeasuredBuildingExtrusionCandidate] = []
        filtered.reserveCapacity(measuredCandidates.count)

        let groupedByBuilding = Dictionary(grouping: measuredCandidates, by: \.candidate.buildingId)
        for (_, buildingCandidates) in groupedByBuilding {
            let uniqueCandidates = deduplicateBuildingExtrusionCandidates(buildingCandidates)
            filtered.append(contentsOf: suppressNestedBuildingExtrusionCandidates(uniqueCandidates))
        }

        return clampEnvelopeBuildingExtrusions(filtered).map(\.candidate)
    }

    /// Some sources (e.g. OpenMapTiles for St. Basil's Cathedral) emit a tall
    /// ground-level OUTER OUTLINE of a parts-modeled building without the usual
    /// `hide_3d` flag. Extruded as-is it becomes one solid box that engulfs the
    /// individually-heighted towers/domes inside it. Detect such an envelope - a
    /// base-0 candidate whose footprint encloses many stacked (base>0) parts from
    /// OTHER buildings - and clamp its top down, leaving a solid pedestal while
    /// the parts articulate everything above.
    ///
    /// Two kinds of buildings meet that footprint test, and only one may be
    /// clamped. A parts-modeled landmark (St. Basil's, the Kremlin towers) is a
    /// hull: its stacked parts top out AT its declared height - the outline's top
    /// IS the tallest part's tip. A real solid building decorated with rooftop
    /// parts (Moscow's Four Seasons block) is the opposite: its roof slabs and
    /// lanterns sit entirely ABOVE the outline's top. So a significant part
    /// wholly above the top vetoes the clamp, and otherwise the clamp level
    /// descends from the highest significant part down a chain of
    /// height-overlapping parts, stopping at the first vertical gap - a stray
    /// low canopy disconnected from the chain cannot drag the building down to
    /// its base. Tiny parts (chimneys, crosses, dormers) are ignored throughout:
    /// a footprint below `envelopeClampSignificanceRatio` of the envelope can
    /// neither veto nor stand in for removed walls.
    private static let envelopeClampSignificanceRatio: Float = 0.02
    /// Largest vertical gap allowed between parts of the chain, as a fraction of
    /// the envelope height: it smooths over height quantization in the data
    /// without letting the chain jump across a real void.
    private static let envelopeClampChainGapRatio: Float = 0.05

    private func clampEnvelopeBuildingExtrusions(
        _ candidates: [MeasuredBuildingExtrusionCandidate]
    ) -> [MeasuredBuildingExtrusionCandidate] {
        let minEnclosedParts = 4
        guard candidates.count > minEnclosedParts else { return candidates }

        let baseEpsilon: Float = 0.5
        // Only stacked (base>0) parts can witness an envelope; base-0 candidates
        // never enclose themselves because the outer pass skips base>0 entries.
        let stackedIndices = candidates.indices.filter { candidates[$0].candidate.baseHeight > baseEpsilon }
        guard stackedIndices.count >= minEnclosedParts else { return candidates }

        return candidates.map { measured in
            let candidate = measured.candidate
            guard candidate.baseHeight <= baseEpsilon else { return measured }

            let chainTolerance = max(Self.envelopeClampChainGapRatio * candidate.topHeight, 1)
            var enclosedSpans: [(base: Float, top: Float)] = []
            var hasSignificantPartAboveTop = false
            for other in stackedIndices {
                let part = candidates[other]
                guard part.candidate.buildingId != candidate.buildingId,
                      part.area >= Self.envelopeClampSignificanceRatio * measured.area,
                      part.bounds.isInsideOrEqual(to: measured.bounds),
                      isRingContained(part.candidate.clippedExterior, in: candidate.clippedExterior) else {
                    continue
                }
                if part.candidate.baseHeight >= candidate.topHeight - chainTolerance {
                    hasSignificantPartAboveTop = true
                    break
                }
                enclosedSpans.append((part.candidate.baseHeight, part.candidate.topHeight))
            }

            guard hasSignificantPartAboveTop == false,
                  enclosedSpans.count >= minEnclosedParts,
                  var level = enclosedSpans.map(\.top).max() else { return measured }

            var descended = true
            while descended {
                descended = false
                for span in enclosedSpans where span.base < level && span.top + chainTolerance >= level {
                    level = span.base
                    descended = true
                }
            }

            let clampedTop = max(candidate.baseHeight, level)
            guard clampedTop < candidate.topHeight else { return measured }

            let clamped = BuildingExtrusionCandidate(
                styleKey: candidate.styleKey,
                buildingId: candidate.buildingId,
                footprintSignature: candidate.footprintSignature,
                clippedExterior: candidate.clippedExterior,
                clippedInteriors: candidate.clippedInteriors,
                rawExterior: candidate.rawExterior,
                hasRawInteriorRings: candidate.hasRawInteriorRings,
                roof: candidate.roof,
                roofInfo: nil,
                baseHeight: candidate.baseHeight,
                topHeight: clampedTop
            )
            return MeasuredBuildingExtrusionCandidate(candidate: clamped,
                                                      bounds: measured.bounds,
                                                      area: measured.area)
        }
    }

    private func deduplicateBuildingExtrusionCandidates(
        _ candidates: [MeasuredBuildingExtrusionCandidate]
    ) -> [MeasuredBuildingExtrusionCandidate] {
        var seen = Set<BuildingExtrusionCandidateKey>()
        var unique: [MeasuredBuildingExtrusionCandidate] = []
        unique.reserveCapacity(candidates.count)

        for measured in candidates {
            let key = BuildingExtrusionCandidateKey(candidate: measured.candidate)
            if seen.insert(key).inserted {
                unique.append(measured)
            }
        }

        return unique
    }

    private func suppressNestedBuildingExtrusionCandidates(
        _ candidates: [MeasuredBuildingExtrusionCandidate]
    ) -> [MeasuredBuildingExtrusionCandidate] {
        guard candidates.count > 1 else { return candidates }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.area != rhs.area {
                return lhs.area > rhs.area
            }
            if lhs.candidate.baseHeight != rhs.candidate.baseHeight {
                return lhs.candidate.baseHeight < rhs.candidate.baseHeight
            }
            return lhs.candidate.topHeight > rhs.candidate.topHeight
        }

        var kept: [MeasuredBuildingExtrusionCandidate] = []
        kept.reserveCapacity(sortedCandidates.count)

        for measured in sortedCandidates {
            let isNested = kept.contains { container in
                measured.candidate.baseHeight >= container.candidate.baseHeight
                    && measured.candidate.topHeight <= container.candidate.topHeight
                    && measured.bounds.isInsideOrEqual(to: container.bounds)
                    && isRingContained(measured.candidate.clippedExterior, in: container.candidate.clippedExterior)
            }
            if isNested == false {
                kept.append(measured)
            }
        }

        return kept
    }

    private func polygonAreaMagnitude(_ ring: [SIMD2<Float>]) -> Float {
        guard ring.count >= 3 else { return 0 }
        var sum: Float = 0
        for index in 0..<ring.count {
            let next = (index + 1) % ring.count
            sum += ring[index].x * ring[next].y - ring[next].x * ring[index].y
        }
        return abs(sum) * 0.5
    }

    private func isRingContained(_ ring: [SIMD2<Float>], in container: [SIMD2<Float>]) -> Bool {
        guard ring.isEmpty == false, container.count >= 3 else {
            return false
        }

        return ring.allSatisfy { point in
            pointInRing(point, ring: container)
        }
    }

    private func pointInRing(_ point: SIMD2<Float>, ring: [SIMD2<Float>]) -> Bool {
        guard ring.count >= 3 else { return false }

        let epsilon: Float = 0.001
        var isInside = false
        var previous = ring[ring.count - 1]
        for current in ring {
            if pointOnSegment(point, a: previous, b: current, epsilon: epsilon) {
                return true
            }

            // The crossing guard above already rejects edges with
            // previous.y == current.y, so the division is safe; clamping the
            // denominator would flip its sign for downward edges and turn the
            // whole test into a coin flip on concave rings.
            let intersects = ((current.y > point.y) != (previous.y > point.y))
                && (point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x)
            if intersects {
                isInside.toggle()
            }
            previous = current
        }

        return isInside
    }

    private func pointOnSegment(_ point: SIMD2<Float>,
                                a: SIMD2<Float>,
                                b: SIMD2<Float>,
                                epsilon: Float) -> Bool {
        let ab = b - a
        let ap = point - a
        let cross = abs(ab.x * ap.y - ab.y * ap.x)
        if cross > epsilon {
            return false
        }

        let dot = simd_dot(ap, ab)
        if dot < -epsilon {
            return false
        }

        let lengthSquared = simd_dot(ab, ab)
        if dot - lengthSquared > epsilon {
            return false
        }

        return true
    }

    private func footprintBounds(_ ring: [SIMD2<Float>]) -> FootprintBounds {
        guard let first = ring.first else {
            return FootprintBounds(minX: 0, minY: 0, maxX: 0, maxY: 0)
        }

        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in ring.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return FootprintBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private struct FootprintBounds {
        let minX: Float
        let minY: Float
        let maxX: Float
        let maxY: Float

        func isInsideOrEqual(to other: FootprintBounds) -> Bool {
            let epsilon: Float = 0.001
            return minX >= other.minX - epsilon
                && minY >= other.minY - epsilon
                && maxX <= other.maxX + epsilon
                && maxY <= other.maxY + epsilon
        }
    }

    private struct BuildingExtrusionCandidateKey: Hashable {
        let buildingId: UInt64
        let footprintSignature: BuildingFootprintSignature
        let baseHeightBits: UInt32
        let topHeightBits: UInt32

        init(candidate: BuildingExtrusionCandidate) {
            self.buildingId = candidate.buildingId
            self.footprintSignature = candidate.footprintSignature
            self.baseHeightBits = candidate.baseHeight.bitPattern
            self.topHeightBits = candidate.topHeight.bitPattern
        }
    }

    func addBorder(
        polygonByStyle: inout [UInt8: [ParsedPolygon]],
        styles: inout [UInt8: FeatureStyle],
        borderWidth: Int16
    ) {
        let style = determineFeatureStyle.makeStyle(data: DetFeatureStyleData(
            layerName: "border",
            properties: [:],
            tile: Tile(x: 0, y: 0, z: 0))
        )
        
        let tileSize: Int16 = 4096
        var polygons = [ParsedPolygon]()
        
        // Bottom border
        var vertices: [SIMD2<Int16>] = [
            SIMD2(0, 0),
            SIMD2(tileSize, 0),
            SIMD2(0, borderWidth),
            SIMD2(tileSize, borderWidth)
        ]
        var indices: [UInt32] = [0, 2, 1, 1, 2, 3]
        polygons.append(ParsedPolygon(vertices: vertices, indices: indices))
        
        // Top border
        vertices = [
            SIMD2(0, tileSize - borderWidth),
            SIMD2(tileSize, tileSize - borderWidth),
            SIMD2(0, tileSize),
            SIMD2(tileSize, tileSize)
        ]
        indices = [0, 2, 1, 1, 2, 3]
        polygons.append(ParsedPolygon(vertices: vertices, indices: indices))
        
        // Left border
        vertices = [
            SIMD2(0, 0),
            SIMD2(borderWidth, 0),
            SIMD2(0, tileSize),
            SIMD2(borderWidth, tileSize)
        ]
        indices = [0, 2, 1, 1, 2, 3]
        polygons.append(ParsedPolygon(vertices: vertices, indices: indices))
        
        // Right border
        vertices = [
            SIMD2(tileSize - borderWidth, 0),
            SIMD2(tileSize, 0),
            SIMD2(tileSize - borderWidth, tileSize),
            SIMD2(tileSize, tileSize)
        ]
        indices = [0, 2, 1, 1, 2, 3]
        polygons.append(ParsedPolygon(vertices: vertices, indices: indices))
        
        polygonByStyle[style.key] = polygons
        styles[style.key] = style
    }
    
    func addBackground(
        polygonByStyle: inout [UInt8: [ParsedPolygon]],
        styles: inout [UInt8: FeatureStyle],
        tile: Tile
    ) {
        // The real tile, not a placeholder: the background color is
        // zoom-banded (overview grass, land base, street land), and a
        // hardcoded z0 froze every tile on the overview branch, painting the
        // vegetation tone under the whole map at every zoom.
        let style = determineFeatureStyle.makeStyle(data: DetFeatureStyleData(
            layerName: "background",
            properties: [:],
            tile: tile)
        )
        
        let numSegments: Int = 64 // Adjustable number of segments per side; change as needed
        let step: Int16 = Int16(4096 / numSegments)

        // Generate vertices: (numSegments + 1) x (numSegments + 1) grid
        var vertices = [SIMD2<Int16>]()
        for i in 0...numSegments {
            for j in 0...numSegments {
                let x = Int16(i) * step
                let y = Int16(j) * step
                vertices.append(SIMD2(x, y))
            }
        }

        // Generate indices for triangles: two triangles per quad
        var indices = [UInt32]()
        let numVerticesPerRow = UInt32(numSegments + 1)
        for i in 0..<numSegments {
            for j in 0..<numSegments {
                let a = UInt32(i * Int(numVerticesPerRow) + j)
                let b = a + 1
                let c = UInt32((i + 1) * Int(numVerticesPerRow) + j)
                let d = c + 1
                
                // First triangle: a -> c -> b (counter-clockwise assuming y-up)
                indices.append(a)
                indices.append(c)
                indices.append(b)
                
                // Second triangle: b -> c -> d (counter-clockwise assuming y-up)
                indices.append(b)
                indices.append(c)
                indices.append(d)
            }
        }

        let parsedPolygon = ParsedPolygon(vertices: vertices, indices: indices)
        
        polygonByStyle[style.key, default: []].insert(parsedPolygon, at: 0)
        styles[style.key] = style
    }

    /// Puts a carriageway-surface polygon (a junction area) into the road
    /// phases: the triangulated polygon under the style's fill pass, and each
    /// ring, closed, tessellated as a kerb under the casing pass. Both carry
    /// the style's class priority so they sort among the roads of that class:
    /// the surface is drawn after the ribbons' casings of its class and under
    /// their fills, exactly where a ribbon's own fill would go, so the ribbons
    /// entering the junction merge into it and their kerbs stop at its edge.
    func appendRoadSurfaceArea(parsedGeometry: ParsePolygon.ParsedGeometry,
                               clippedExterior: [SIMD2<Float>],
                               clippedInteriors: [[SIMD2<Float>]],
                               style: FeatureStyle,
                               attributes: [String: VectorTile_Tile.Value],
                               roadStyles: inout [UInt8: FeatureStyle],
                               roadPolygonByStyle: inout [UInt8: [ParsedPolygon]],
                               orderedRoadPolygons: inout [OrderedRoadPolygon],
                               roadPolygonSequence: inout Int,
                               parseLine: ParseLine) {
        let structure: RoadStructureKind = roadStructureKind(attributes: attributes) == .ground
            ? .automobileGround
            : roadStructureKind(attributes: attributes)
        let layer = roadLayerValue(attributes: attributes)
        for pass in style.resolvedLineRenderPasses {
            let passStyle = FeatureStyle(
                key: pass.key,
                color: pass.color,
                streetColor: pass.streetColor,
                lowZoomFadeMask: pass.lowZoomFadeMask,
                parseGeometryStyleData: pass.parseGeometryStyleData,
                roadClassPriority: style.roadClassPriority
            )
            if roadStyles[pass.key] == nil {
                roadStyles[pass.key] = passStyle
            }
            var polygons: [ParsedPolygon] = []
            switch pass.roadPassRole {
            case .fill:
                polygons = [parsedGeometry.parsedPolygon]
            case .casing:
                // Each ring as a closed line: the first two points repeat at
                // the end so the closing corner gets a join like every other.
                //
                // The rings arrive in render space, where `ParsePolygon` has
                // already flipped y; the line tessellator takes tile space and
                // flips it itself. Handing it a flipped ring drew every kerb
                // mirrored about the tile's mid-line, which is a dark outline
                // across whatever happened to lie there (a park, a block of
                // buildings) and nothing around the junction it belongs to.
                for ring in [clippedExterior] + clippedInteriors where ring.count >= 3 {
                    let tileSpaceRing = ring.map { SIMD2<Float>($0.x, Float(tileExtent) - $0.y) }
                    var closed = tileSpaceRing
                    closed.append(tileSpaceRing[0])
                    closed.append(tileSpaceRing[1])
                    if let kerb = parseLine.parse(points: closed,
                                                  width: pass.parseGeometryStyleData.lineWidth,
                                                  tileExtent: Float(tileExtent),
                                                  startCapRound: false,
                                                  endCapRound: false,
                                                  lineJoinRound: true,
                                                  clipGeometryToTileBounds: true) {
                        polygons.append(kerb)
                    }
                }
            default:
                continue
            }
            for polygon in polygons {
                roadPolygonByStyle[pass.key, default: []].append(polygon)
                orderedRoadPolygons.append(
                    OrderedRoadPolygon(polygon: polygon,
                                       styleKey: pass.key,
                                       structureKind: structure,
                                       layer: layer,
                                       classPriority: style.roadClassPriority,
                                       passRole: pass.roadPassRole,
                                       sequence: roadPolygonSequence)
                )
                roadPolygonSequence += 1
            }
        }
    }
}
