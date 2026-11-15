// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

struct VectorTileLabelPriority: Equatable {
    let visibilityRank: Int
    let collisionRank: Int
    let deduplicationRank: Int
    let drawRank: Int

    init(visibilityRank: Int,
         collisionRank: Int,
         deduplicationRank: Int,
         drawRank: Int) {
        self.visibilityRank = visibilityRank
        self.collisionRank = collisionRank
        self.deduplicationRank = deduplicationRank
        self.drawRank = drawRank
    }
}
