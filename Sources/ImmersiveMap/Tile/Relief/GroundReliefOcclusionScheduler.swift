// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// Computes the terrain tiles' occlusion of the sky (`GroundReliefOcclusion`)
/// off the main thread, for the terrain store (`GroundReliefStore`): a
/// tile's as it is decoded, on the load's own task, and every tile's again
/// on a queue of its own when what it is computed with changes (the key).
/// The store hands the tiles in and takes each result back under its own
/// lock, so a tile's occlusion is written and read in one place.
///
/// Each change of the key starts a generation: a computation under way for
/// an older one stops, and its results are not taken
/// (`isCurrent(_:)`, which the store asks under its lock).
///
/// Thread-safe (`@unchecked Sendable`): the key, the generation and the
/// timing are serialized by `lock`, always taken after the store's.
final class GroundReliefOcclusionScheduler: @unchecked Sendable {
    typealias Key = GroundReliefOcclusion.Key

    /// What a draw samples for a tile whose occlusion is not computed:
    /// one texel of 0, no darkening.
    let fallbackTexture: MTLTexture?

    private let device: MTLDevice
    private let queue = DispatchQueue(label: "ImmersiveMap.GroundReliefOcclusion", qos: .utility)
    private let lock = NSLock()
    private var currentKey: Key
    /// Grows with every change of the key.
    private var generation: UInt64 = 0
    private var lastMilliseconds: Double = 0

    init(device: MTLDevice, key: Key) {
        self.device = device
        self.currentKey = key
        self.fallbackTexture = Self.makeTexture(device: device, bytes: [0], resolution: 1)
    }

    /// The key the tiles' occlusion is computed with now: a tile computed
    /// under another draws none.
    var key: Key {
        lock.lock()
        defer { lock.unlock() }
        return currentKey
    }

    /// How long the last tile's occlusion took to compute, in milliseconds.
    var millisecondsLast: Double {
        lock.lock()
        defer { lock.unlock() }
        return lastMilliseconds
    }

    /// A new key: the generation it starts, nil for the key of the moment,
    /// which starts nothing.
    func begin(_ key: Key) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard key != currentKey else { return nil }
        currentKey = key
        generation &+= 1
        return generation
    }

    /// Whether a generation is still the current one.
    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }

    /// The occlusion of a tile just decoded, under the key of the moment,
    /// before the tile is in: on the load's own task.
    func compute(tile: Tile, terrain: GroundReliefTile) -> (texture: MTLTexture?, key: Key) {
        let key = self.key
        return (compute(tile: tile, size: terrain.size, halves: terrain.halves, key: key), key)
    }

    /// Computes every tile of `tiles` under `key` on the queue, nearest
    /// first as given, handing each result to `deliver` while `generation`
    /// is current, and stopping once it is not.
    func recompute(_ tiles: [(tile: Tile, terrain: GroundReliefTile, halves: [UInt16])],
                   key: Key,
                   generation: UInt64,
                   deliver: @escaping @Sendable (GroundReliefTile, MTLTexture?) -> Void) {
        queue.async { [weak self] in
            for entry in tiles {
                guard let self, self.isCurrent(generation) else { return }
                let texture = self.compute(tile: entry.tile, size: entry.terrain.size, halves: entry.halves, key: key)
                deliver(entry.terrain, texture)
            }
        }
    }

    /// The occlusion of a tile's heights as a texture, nil under a key
    /// that computes nothing. Off the main thread.
    private func compute(tile: Tile, size: Int, halves: [UInt16], key: Key) -> MTLTexture? {
        guard key.computes else { return nil }
        let started = CFAbsoluteTimeGetCurrent()
        let bytes = GroundReliefOcclusion.compute(halves: halves,
                                                  size: size,
                                                  metresPerTexel: GroundReliefOcclusion.metresPerTexel(tile: tile, size: size),
                                                  key: key)
        let texture = Self.makeTexture(device: device, bytes: bytes, resolution: key.resolution)
        let milliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
        lock.lock()
        lastMilliseconds = milliseconds
        lock.unlock()
        return texture
    }

    private static func makeTexture(device: MTLDevice, bytes: [UInt8], resolution: Int) -> MTLTexture? {
        guard resolution > 0, bytes.count == resolution * resolution else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                  width: resolution,
                                                                  height: resolution,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { pointer in
            texture.replace(region: MTLRegionMake2D(0, 0, resolution, resolution),
                            mipmapLevel: 0,
                            withBytes: pointer.baseAddress!,
                            bytesPerRow: resolution)
        }
        return texture
    }
}
