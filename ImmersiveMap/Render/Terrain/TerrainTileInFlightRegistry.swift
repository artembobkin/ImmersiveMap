// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct TerrainTileInFlightToken: Hashable {
    private let id = UUID()
}

final class TerrainTileInFlightRegistry {
    private final class Entry {
        let token: TerrainTileInFlightToken
        var task: Task<Void, Never>?

        init(token: TerrainTileInFlightToken) {
            self.token = token
        }
    }

    private var entriesByKey: [TerrainTileCacheKey: Entry] = [:]

    func contains(_ key: TerrainTileCacheKey) -> Bool {
        entriesByKey[key] != nil
    }

    func contains(key: TerrainTileCacheKey,
                  token: TerrainTileInFlightToken) -> Bool {
        entriesByKey[key]?.token == token
    }

    func reserve(key: TerrainTileCacheKey) -> TerrainTileInFlightToken? {
        guard entriesByKey[key] == nil else {
            return nil
        }

        let token = TerrainTileInFlightToken()
        entriesByKey[key] = Entry(token: token)
        return token
    }

    func attach(_ task: Task<Void, Never>,
                for key: TerrainTileCacheKey,
                token: TerrainTileInFlightToken) -> Bool {
        guard let entry = entriesByKey[key],
              entry.token == token else {
            return false
        }

        entry.task = task
        return true
    }

    @discardableResult
    func finish(key: TerrainTileCacheKey,
                token: TerrainTileInFlightToken) -> Bool {
        guard let entry = entriesByKey[key],
              entry.token == token else {
            return false
        }

        entriesByKey[key] = nil
        return true
    }

    func cancelAll() {
        let tasks = entriesByKey.values.compactMap(\.task)
        entriesByKey.removeAll()
        for task in tasks {
            task.cancel()
        }
    }
}
