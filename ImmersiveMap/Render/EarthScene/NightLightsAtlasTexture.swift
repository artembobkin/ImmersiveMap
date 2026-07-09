// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class NightLightsAtlasTexture {
    private static let defaultPageSize = 4096
    private static let defaultTileSize = 1024
    private static let bytesPerPixel = 2

    private let device: MTLDevice
    private let pageSize: Int
    private let tileSize: Int
    private let slotsPerSide: Int
    private let slotsPerPage: Int

    private var pages: [MTLTexture] = []
    private var tileSlots: [Tile: Int] = [:]
    private var freeSlots: [Int] = []
    private var nextSlotIndex: Int = 0

    init(device: MTLDevice, pageSize: Int = 4096, tileSize: Int = 1024) {
        let geometry = Self.validatedGeometry(pageSize: pageSize, tileSize: tileSize)
        self.device = device
        self.pageSize = geometry.pageSize
        self.tileSize = geometry.tileSize
        self.slotsPerSide = geometry.pageSize / geometry.tileSize
        self.slotsPerPage = slotsPerSide * slotsPerSide
    }

    // Shaders must only sample slots described by `entries`; untouched slots are not part of the atlas contract.
    func update(tiles: [NightLightsTileData]) -> NightLightsAtlasState {
        let validTiles = tiles.filter(isValid)
        guard !validTiles.isEmpty else {
            removeAll()
            return .empty
        }

        var requiredTiles = Set<Tile>()
        for tileData in validTiles {
            requiredTiles.insert(tileData.tile)
        }
        removeSlotsNotIn(requiredTiles)

        var entries: [NightLightsAtlasEntry] = []
        entries.reserveCapacity(validTiles.count)

        for tileData in validTiles {
            let slotIndex: Int
            let shouldUpload: Bool
            if let existingSlotIndex = tileSlots[tileData.tile] {
                slotIndex = existingSlotIndex
                shouldUpload = false
            } else {
                slotIndex = allocateSlot(for: tileData.tile)
                shouldUpload = true
            }

            let layout = slotLayout(for: slotIndex)
            guard let page = texturePage(at: layout.pageIndex) else {
                continue
            }
            guard let tileBytesPerRow = Self.bytesPerRow(forSideLength: tileSize) else {
                continue
            }

            if shouldUpload {
                let region = MTLRegionMake2D(layout.originX, layout.originY, tileSize, tileSize)
                tileData.bytes.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return
                    }
                    page.replace(region: region,
                                 mipmapLevel: 0,
                                 withBytes: baseAddress,
                                 bytesPerRow: tileBytesPerRow)
                }
            }

            let uvScale = SIMD2<Float>(Float(tileSize) / Float(pageSize),
                                       Float(tileSize) / Float(pageSize))
            let uvOrigin = SIMD2<Float>(Float(layout.originX) / Float(pageSize),
                                        Float(layout.originY) / Float(pageSize))
            entries.append(NightLightsAtlasEntry(tile: tileData.tile,
                                                 pageIndex: layout.pageIndex,
                                                 uvOrigin: uvOrigin,
                                                 uvScale: uvScale))
        }

        if entries.isEmpty {
            removeAll()
            return .empty
        }

        let exposedPages = Array(pages.prefix(requiredPageCount(forSlotIndices: tileSlots.values)))
        if exposedPages.count < pages.count {
            pages = exposedPages
        }
        return NightLightsAtlasState(pages: exposedPages, entries: entries)
    }

    func removeAll() {
        pages.removeAll()
        tileSlots.removeAll()
        freeSlots.removeAll()
        nextSlotIndex = 0
    }

    private func isValid(_ tileData: NightLightsTileData) -> Bool {
        guard let expectedByteCount = Self.textureByteCount(forSideLength: tileSize) else {
            return false
        }
        return tileData.width == tileSize &&
        tileData.height == tileSize &&
        tileData.bytes.count == expectedByteCount
    }

    private func texturePage(at index: Int) -> MTLTexture? {
        while pages.count <= index {
            guard let texture = makeTexturePage(index: pages.count) else {
                return nil
            }
            pages.append(texture)
        }
        return pages[index]
    }

    private func makeTexturePage(index: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm,
                                                                  width: pageSize,
                                                                  height: pageSize,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "NightLightsAtlasTexturePage\(index)"
        return texture
    }

    private func removeSlotsNotIn(_ requiredTiles: Set<Tile>) {
        for (tile, slotIndex) in tileSlots where !requiredTiles.contains(tile) {
            tileSlots.removeValue(forKey: tile)
            freeSlots.append(slotIndex)
        }
        freeSlots.sort()
    }

    private func allocateSlot(for tile: Tile) -> Int {
        let slotIndex: Int
        if freeSlots.isEmpty {
            slotIndex = nextSlotIndex
            nextSlotIndex += 1
        } else {
            slotIndex = freeSlots.removeFirst()
        }
        tileSlots[tile] = slotIndex
        return slotIndex
    }

    private func slotLayout(for slotIndex: Int) -> (pageIndex: Int, originX: Int, originY: Int) {
        let pageIndex = slotIndex / slotsPerPage
        let slotInPage = slotIndex % slotsPerPage
        let column = slotInPage % slotsPerSide
        let row = slotInPage / slotsPerSide
        return (pageIndex: pageIndex,
                originX: column * tileSize,
                originY: row * tileSize)
    }

    private func requiredPageCount(forSlotIndices slotIndices: Dictionary<Tile, Int>.Values) -> Int {
        guard let maxSlotIndex = slotIndices.max() else {
            return 0
        }
        return (maxSlotIndex / slotsPerPage) + 1
    }

    private static func validatedGeometry(pageSize: Int, tileSize: Int) -> (pageSize: Int, tileSize: Int) {
        guard pageSize > 0,
              tileSize > 0,
              tileSize <= pageSize,
              pageSize % tileSize == 0,
              bytesPerRow(forSideLength: tileSize) != nil,
              bytesPerRow(forSideLength: pageSize) != nil,
              textureByteCount(forSideLength: tileSize) != nil,
              textureByteCount(forSideLength: pageSize) != nil else {
            return (defaultPageSize, defaultTileSize)
        }

        let slotsPerSide = pageSize / tileSize
        guard checkedProduct(slotsPerSide, slotsPerSide) != nil else {
            return (defaultPageSize, defaultTileSize)
        }
        return (pageSize, tileSize)
    }

    private static func bytesPerRow(forSideLength sideLength: Int) -> Int? {
        checkedProduct(sideLength, bytesPerPixel)
    }

    private static func textureByteCount(forSideLength sideLength: Int) -> Int? {
        guard let pixelCount = checkedProduct(sideLength, sideLength) else {
            return nil
        }
        return checkedProduct(pixelCount, bytesPerPixel)
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }
}
