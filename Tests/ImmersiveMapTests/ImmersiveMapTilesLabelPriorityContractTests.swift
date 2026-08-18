// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Pins the one-number label-priority contract
/// (Documentation/docs/label-priority-in-tiles.md): `rank` is the whole
/// signal, lower is more important, and a feature without a rank is the least
/// important thing in its layer. There is no second mechanism to reconcile:
/// the tiles bake population and capital status into the rank at build time,
/// so the profile must not resurrect them as fallbacks.
final class ImmersiveMapTilesLabelPriorityContractTests: XCTestCase {
    private func intValue(_ value: Int) -> VectorTile_Tile.Value {
        var v = VectorTile_Tile.Value()
        v.intValue = Int64(value)
        return v
    }

    private func makeProfile() -> ImmersiveMapTilesVectorTileLabelProviderProfile {
        ImmersiveMapTilesVectorTileLabelProviderProfile(settings: .default)
    }

    func testRankIsTheSortKey() {
        let profile = makeProfile()
        XCTAssertEqual(profile.sortKey(properties: ["rank": intValue(1)]), 1)
        XCTAssertEqual(profile.sortKey(properties: ["rank": intValue(7)]), 7)
    }

    func testAbsentRankIsLeastImportantEvenWithLegacySignalsPresent() {
        let profile = makeProfile()
        let noRank = profile.sortKey(properties: [:])
        XCTAssertEqual(profile.sortKey(properties: ["capital": intValue(2)]), noRank,
                       "capital must not float a rankless feature up")
        XCTAssertEqual(profile.sortKey(properties: ["population": intValue(13_000_000)]), noRank,
                       "population must not float a rankless feature up")
        XCTAssertGreaterThan(noRank, 10, "absent rank sits below every ranked place (1..10)")
    }

    func testRankOutranksAnyLegacySignal() {
        let profile = makeProfile()
        let rankedVillage = profile.sortKey(properties: ["rank": intValue(9)])
        let ranklessMetropolis = profile.sortKey(properties: ["population": intValue(13_000_000)])
        XCTAssertLessThan(rankedVillage, ranklessMetropolis)
    }
}
