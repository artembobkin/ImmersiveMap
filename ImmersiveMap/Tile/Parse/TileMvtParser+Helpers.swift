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

    func decodeAttributes(feature: VectorTile_Tile.Feature,
                          layer: VectorTile_Tile.Layer) -> [String: VectorTile_Tile.Value] {
        var attributes: [String: VectorTile_Tile.Value] = [:]
        for i in stride(from: 0, to: feature.tags.count, by: 2) {
            guard i + 1 < feature.tags.count else { break }
            let keyIndex = Int(feature.tags[i])
            let valueIndex = Int(feature.tags[i + 1])

            guard keyIndex < layer.keys.count,
                  valueIndex < layer.values.count else { continue }

            let key = layer.keys[keyIndex]
            let value = layer.values[valueIndex]
            attributes[key] = value
        }
        return attributes
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

    func collectBuildingPartIds(layer: VectorTile_Tile.Layer) -> Set<UInt64> {
        var partIds = Set<UInt64>()
        for feature in layer.features {
            let attributes = decodeAttributes(feature: feature, layer: layer)
            if isTruthy(attributes["building:part"]) {
                let id = buildingIdentifier(attributes: attributes, featureId: feature.id)
                partIds.insert(id)
            }
        }
        return partIds
    }

    func collectBuildingPartFootprintSignatures(layer: VectorTile_Tile.Layer) -> Set<BuildingFootprintSignature> {
        var signatures = Set<BuildingFootprintSignature>()
        let polygonDecoder = DecodePolygon()
        for feature in layer.features {
            let attributes = decodeAttributes(feature: feature, layer: layer)
            guard isTruthy(attributes["building:part"]) else { continue }
            let polygons = normalize(polygonDecoder.decode(geometry: feature.geometry), layer: layer)
            for polygon in polygons {
                if let signature = buildingFootprintSignature(for: polygon) {
                    signatures.insert(signature)
                }
            }
        }
        return signatures
    }

    func normalize(_ polygons: MultiPolygon, layer: VectorTile_Tile.Layer) -> MultiPolygon {
        let scale = coordinateScale(for: layer)
        guard scale != 1 else {
            return polygons
        }
        return polygons.map { polygon in
            Polygon(exteriorRing: normalize(polygon.exteriorRing, scale: scale),
                    interiorRings: polygon.interiorRings.map { normalize($0, scale: scale) })
        }
    }

    func normalize(_ lines: MultiLineString, layer: VectorTile_Tile.Layer) -> MultiLineString {
        let scale = coordinateScale(for: layer)
        guard scale != 1 else {
            return lines
        }
        return lines.map { normalize($0, scale: scale) }
    }

    func normalize(_ points: MultiPoint, layer: VectorTile_Tile.Layer) -> MultiPoint {
        let scale = coordinateScale(for: layer)
        guard scale != 1 else {
            return points
        }
        return normalize(points, scale: scale)
    }

    private func coordinateScale(for layer: VectorTile_Tile.Layer) -> Double {
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
            RoofInfo(height: $0.height * style.extrusionHeightScale * zoomScale, shape: $0.shape)
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
        let roofField = roofInfo.flatMap {
            RoofHeightField(roof: $0, exteriorRing: sanitizedExterior, baseHeight: baseHeight, topHeight: topHeight)
        }
        let roofOffset = UInt32(vertices.count)
        if roof.indices.count >= 3 {
            let roofSurfaceID = nextLocalSurfaceID
            nextLocalSurfaceID &+= 1
            if let roofField {
                let roofPositions: [SIMD3<Float>] = roof.vertices.map {
                    let xy = SIMD2<Float>(Float($0.x), Float($0.y))
                    return SIMD3<Float>(xy.x, xy.y, roofField.height(at: xy))
                }
                var roofNormals = Array(repeating: SIMD3<Float>(0, 0, 0), count: roofPositions.count)
                var roofIndices: [UInt32] = []
                roofIndices.reserveCapacity(roof.indices.count)
                for i in stride(from: 0, to: roof.indices.count, by: 3) {
                    if i + 2 >= roof.indices.count { break }
                    let i0 = roof.indices[i]
                    let i1 = roof.indices[i + 1]
                    let i2 = roof.indices[i + 2]
                    roofIndices.append(i0)
                    roofIndices.append(i2)
                    roofIndices.append(i1)
                    let p0 = roofPositions[Int(i0)]
                    let p1 = roofPositions[Int(i2)]
                    let p2 = roofPositions[Int(i1)]
                    let normal = simd_normalize(simd_cross(p1 - p0, p2 - p0))
                    if normal.x.isNaN || normal.y.isNaN || normal.z.isNaN {
                        continue
                    }
                    roofNormals[Int(i0)] += normal
                    roofNormals[Int(i2)] += normal
                    roofNormals[Int(i1)] += normal
                }
                for i in 0..<roofPositions.count {
                    let normal = roofNormals[i]
                    let normalized = simd_length(normal) > 0.0001 ? simd_normalize(normal) : SIMD3<Float>(0, 0, 1)
                    vertices.append(ParsedExtrudedVertex(position: roofPositions[i],
                                                         normal: normalized,
                                                         surfaceID: roofSurfaceID))
                }
                indices.append(contentsOf: roofIndices.map { $0 + roofOffset })
            } else {
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
        }

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
                let top0 = roofField?.height(at: p0) ?? topHeight
                let top1 = roofField?.height(at: p1) ?? topHeight
                let v2 = SIMD3<Float>(p1.x, p1.y, top1)
                let v3 = SIMD3<Float>(p0.x, p0.y, top0)
                let wallNormal = simd_normalize(simd_cross(v1 - v0, v2 - v0))
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

        // Exterior: CW so walls are front-facing with back culling in current tile space
        appendWalls(for: sanitizedExterior, clockwise: true, isSanitized: true)
        for interior in clippedInteriors {
            // Interior (hole): opposite winding
            appendWalls(for: interior, clockwise: false)
        }
        
        return indices.isEmpty ? nil : ParsedExtrudedMesh(vertices: vertices, indices: indices)
    }

    func resolveExteriorBuildingExtrusions(_ candidates: [BuildingExtrusionCandidate]) -> [BuildingExtrusionCandidate] {
        guard candidates.count > 1 else { return candidates }

        var filtered: [BuildingExtrusionCandidate] = []
        filtered.reserveCapacity(candidates.count)

        let groupedByBuilding = Dictionary(grouping: candidates, by: \.buildingId)
        for (_, buildingCandidates) in groupedByBuilding {
            let uniqueCandidates = deduplicateBuildingExtrusionCandidates(buildingCandidates)
            filtered.append(contentsOf: suppressNestedBuildingExtrusionCandidates(uniqueCandidates))
        }

        return clampEnvelopeBuildingExtrusions(filtered)
    }

    /// Some sources (e.g. OpenMapTiles for St. Basil's Cathedral) emit a tall
    /// ground-level OUTER OUTLINE of a parts-modeled building without the usual
    /// `hide_3d` flag. Extruded as-is it becomes one solid box that engulfs the
    /// individually-heighted towers/domes inside it. Detect such an envelope - a
    /// base-0 candidate whose footprint encloses many stacked (base>0) parts from
    /// OTHER buildings - and clamp its top down to the lowest enclosed part's base,
    /// leaving a solid pedestal while the parts articulate everything above.
    private func clampEnvelopeBuildingExtrusions(_ candidates: [BuildingExtrusionCandidate]) -> [BuildingExtrusionCandidate] {
        let minEnclosedParts = 4
        guard candidates.count > minEnclosedParts else { return candidates }

        let baseEpsilon: Float = 0.5
        let bounds = candidates.map { footprintBounds($0.clippedExterior) }

        return candidates.enumerated().map { index, candidate in
            guard candidate.baseHeight <= baseEpsilon else { return candidate }
            let envelopeBounds = bounds[index]

            var minStackedBase = Float.greatestFiniteMagnitude
            var enclosedCount = 0
            for other in candidates.indices where other != index {
                let part = candidates[other]
                guard part.buildingId != candidate.buildingId,
                      part.baseHeight > baseEpsilon,
                      bounds[other].isInsideOrEqual(to: envelopeBounds),
                      isRingContained(part.clippedExterior, in: candidate.clippedExterior) else {
                    continue
                }
                enclosedCount += 1
                minStackedBase = min(minStackedBase, part.baseHeight)
            }

            guard enclosedCount >= minEnclosedParts else { return candidate }
            let clampedTop = max(candidate.baseHeight, minStackedBase)
            guard clampedTop < candidate.topHeight else { return candidate }

            return BuildingExtrusionCandidate(
                styleKey: candidate.styleKey,
                buildingId: candidate.buildingId,
                footprintSignature: candidate.footprintSignature,
                clippedExterior: candidate.clippedExterior,
                clippedInteriors: candidate.clippedInteriors,
                roof: candidate.roof,
                roofInfo: nil,
                baseHeight: candidate.baseHeight,
                topHeight: clampedTop
            )
        }
    }

    private func deduplicateBuildingExtrusionCandidates(_ candidates: [BuildingExtrusionCandidate]) -> [BuildingExtrusionCandidate] {
        var seen = Set<BuildingExtrusionCandidateKey>()
        var unique: [BuildingExtrusionCandidate] = []
        unique.reserveCapacity(candidates.count)

        for candidate in candidates {
            let key = BuildingExtrusionCandidateKey(candidate: candidate)
            if seen.insert(key).inserted {
                unique.append(candidate)
            }
        }

        return unique
    }

    private func suppressNestedBuildingExtrusionCandidates(_ candidates: [BuildingExtrusionCandidate]) -> [BuildingExtrusionCandidate] {
        guard candidates.count > 1 else { return candidates }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            let lhsArea = polygonAreaMagnitude(lhs.clippedExterior)
            let rhsArea = polygonAreaMagnitude(rhs.clippedExterior)
            if lhsArea != rhsArea {
                return lhsArea > rhsArea
            }
            if lhs.baseHeight != rhs.baseHeight {
                return lhs.baseHeight < rhs.baseHeight
            }
            return lhs.topHeight > rhs.topHeight
        }

        var kept: [BuildingExtrusionCandidate] = []
        kept.reserveCapacity(sortedCandidates.count)

        for candidate in sortedCandidates {
            let isNested = kept.contains { container in
                candidate.baseHeight >= container.baseHeight
                    && candidate.topHeight <= container.topHeight
                    && footprintBounds(candidate.clippedExterior).isInsideOrEqual(to: footprintBounds(container.clippedExterior))
                    && isRingContained(candidate.clippedExterior, in: container.clippedExterior)
            }
            if isNested == false {
                kept.append(candidate)
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

            let intersects = ((current.y > point.y) != (previous.y > point.y))
                && (point.x < (previous.x - current.x) * (point.y - current.y) / max(previous.y - current.y, epsilon) + current.x)
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
        styles: inout [UInt8: FeatureStyle]
    ) {
        let style = determineFeatureStyle.makeStyle(data: DetFeatureStyleData(
            layerName: "background",
            properties: [:],
            tile: Tile(x: 0, y: 0, z: 0))
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
}
