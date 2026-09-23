// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// Stitches the pieces of one street back into one polyline before
/// tessellation.
///
/// A street often arrives as several features: OSM way boundaries the tile
/// pipeline did not merge, or cuts the tiler made. Drawn as separate ribbons,
/// every boundary between two pieces is a seam: two caps, a kerb crossing the
/// carriageway, a dash pattern restarting. Stitching joins pieces end to end
/// when, and only when, they are the same street to draw, meeting at an
/// endpoint that no third road shares.
///
/// Which street a piece belongs to is the schema reading's answer, guessed
/// from the name and every drawing attribute, which is right within a tile
/// and refuses to join two pieces whose lane counts the tiler happened to
/// write differently. The attributes that change how a piece is drawn must
/// agree: a street runs into a tunnel and out again, and those are one
/// street but not one ribbon.
///
/// A node where a third road meets is a junction, and a street may pass
/// through it only as its own geometry, never glued across it: gluing there
/// would weld two streets meeting at a T into one bent ribbon.
///
/// The result keeps the feature indexing: the first feature of a chain
/// receives the whole stitched polyline, the others receive nothing, so the
/// caller's per-feature styling and bookkeeping stay intact.
enum RoadStreetStitcher {
    /// Which pieces are one street, and what still has to agree between
    /// them (a street runs into a tunnel and out again, and the two pieces
    /// are one street but not one ribbon), is the schema reading's
    /// `ImmersiveMapRoadFacts.stitchingKey`. Pieces with equal keys stitch;
    /// a piece without a key passes through untouched. Which pieces are
    /// roads of the drive tier is the style's `roadTier`.
    static func stitch(linesByFeatureIndex: [[[SIMD2<Float>]]],
                       featureFacts: [ImmersiveMapFeatureFacts],
                       featureStyles: [FeatureStyle]) -> [[[SIMD2<Float>]]] {
        let featureCount = linesByFeatureIndex.count
        guard featureCount > 1 else { return linesByFeatureIndex }

        // Only features with a stitching key take part; everything else
        // passes through untouched. Without a name on the geometry the tiles
        // give the engine nothing to stitch on.
        var identityByFeature = [String?](repeating: nil, count: featureCount)
        var participates = false
        for index in 0..<featureCount where linesByFeatureIndex[index].isEmpty == false {
            guard let road = featureFacts[index].road,
                  featureStyles[index].roadStyle?.tier == .automobile,
                  let key = road.stitchingKey else {
                continue
            }
            identityByFeature[index] = key
            participates = true
        }
        guard participates else { return linesByFeatureIndex }

        // Each piece: one polyline (features with several parts are left as
        // they are; a multi-part street is already a set of separate ribbons).
        struct Piece {
            let feature: Int
            var points: [SIMD2<Float>]
            var consumed = false
        }
        var pieces: [Piece] = []
        var pieceIndexByFeature = [Int?](repeating: nil, count: featureCount)
        for index in 0..<featureCount {
            guard identityByFeature[index] != nil,
                  linesByFeatureIndex[index].count == 1,
                  linesByFeatureIndex[index][0].count >= 2 else {
                continue
            }
            pieceIndexByFeature[index] = pieces.count
            pieces.append(Piece(feature: index, points: linesByFeatureIndex[index][0]))
        }
        guard pieces.count > 1 else { return linesByFeatureIndex }

        // How many distinct drive-tier features touch each endpoint (any
        // road feature, stitchable or not: a T with an unnamed service road
        // is still a T).
        var featuresAtPoint: [RoadConnectionPointKey: Set<Int>] = [:]
        for index in 0..<featureCount where featureStyles[index].roadStyle?.tier == .automobile {
            for line in linesByFeatureIndex[index] {
                guard let first = line.first, let last = line.last else { continue }
                featuresAtPoint[.init(point: first), default: []].insert(index)
                featuresAtPoint[.init(point: last), default: []].insert(index)
            }
        }

        // Endpoint index over the stitchable pieces: which piece ends at which
        // point, and which end of it.
        struct End {
            let piece: Int
            let isStart: Bool
        }
        var endsAtPoint: [RoadConnectionPointKey: [End]] = [:]
        for (pieceIndex, piece) in pieces.enumerated() {
            endsAtPoint[.init(point: piece.points[0]), default: []].append(End(piece: pieceIndex, isStart: true))
            endsAtPoint[.init(point: piece.points[piece.points.count - 1]), default: []].append(End(piece: pieceIndex, isStart: false))
        }

        func partner(of pieceIndex: Int, atStart: Bool) -> End? {
            let piece = pieces[pieceIndex]
            let point = atStart ? piece.points[0] : piece.points[piece.points.count - 1]
            let key = RoadConnectionPointKey(point: point)
            // Exactly two drive-tier features meet here, or it is a junction.
            guard featuresAtPoint[key]?.count == 2 else { return nil }
            guard let candidates = endsAtPoint[key] else { return nil }
            for candidate in candidates where candidate.piece != pieceIndex {
                let other = pieces[candidate.piece]
                guard other.consumed == false,
                      identityByFeature[other.feature] == identityByFeature[piece.feature] else {
                    continue
                }
                return candidate
            }
            return nil
        }

        var output = linesByFeatureIndex
        for pieceIndex in 0..<pieces.count where pieces[pieceIndex].consumed == false {
            pieces[pieceIndex].consumed = true
            var chain = pieces[pieceIndex].points

            // Grow forward from the end.
            var current = pieceIndex
            var currentEndIsStart = false
            while let next = partner(of: current, atStart: currentEndIsStart) {
                pieces[next.piece].consumed = true
                var points = pieces[next.piece].points
                if next.isStart == false { points.reverse() }
                chain.append(contentsOf: points.dropFirst())
                output[pieces[next.piece].feature] = []
                current = next.piece
                // After appending, the chain's tail is the far end of `next`.
                currentEndIsStart = next.isStart == false
            }
            // Grow backward from the start.
            current = pieceIndex
            currentEndIsStart = true
            while let previous = partner(of: current, atStart: currentEndIsStart) {
                pieces[previous.piece].consumed = true
                var points = pieces[previous.piece].points
                if previous.isStart { points.reverse() }
                chain.insert(contentsOf: points.dropLast(), at: 0)
                output[pieces[previous.piece].feature] = []
                current = previous.piece
                currentEndIsStart = previous.isStart
            }
            output[pieces[pieceIndex].feature] = [chain]
        }
        return output
    }
}
