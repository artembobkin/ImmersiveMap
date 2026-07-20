// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class GlobeTilesTexture {
    private struct TileOverviewFadeUniform {
        var overviewAlpha: Float
        var roadAlpha: Float
        var landuseAlpha: Float
    }

    struct TileData {
        let position: simd_int1
        let textureSize: simd_int1
        let cellSize: simd_int1
        let tile: simd_int3
        let sourceTile: simd_int3
    }

    struct Page {
        let texture: MTLTexture
        var tileData: [TileData]
    }

    let size: Int = 4096
    /// Уровни мипов страницы (0..6): без предфильтрации дальние слоты мерцают.
    /// Глубина до 64:1 нужна крупным слотам (2048 px), которые тянутся до самой
    /// линии горизонта: их последние ряды сжаты перспективой в 20-60 раз.
    /// Уровни глубже 3 почти бесплатны (+0.5% к +33% памяти), а их отсутствие
    /// возвращает рябь ровно в приграничную полосу горизонта.
    static let pageMipLevelCount = 7
    private(set) var pages: [Page] = []
    var projection: matrix_float4x4
    var previousProjectionCount: Int = 0

    private let metalDevice: MTLDevice
    private let tilePipeline: TilePipeline
    // Фон страницы = подложка стиля, а не белый: при глубоких mip-уровнях
    // кромка слота может подмешать фон страницы, и контрастный цвет даёт
    // мигающую светлую линию на стыках тайлов.
    private let pageClearColor: MTLClearColor
    private let depthStencilState: MTLDepthStencilState
    private var renderEncoder: MTLRenderCommandEncoder?
    private var activePageIndex: Int?
    // Depth в атласе не участвует в отрисовке (compare .always, запись выключена),
    // но нужен как атачмент, потому что TilePipeline объявляет depth32Float.
    // Одна общая транзиентная текстура на все страницы вместо 64 МБ на страницу.
    private var sharedDepthTexture: MTLTexture?

    private var previousShiftX: Float? = nil
    private var previousShiftY: Float? = nil
    private var previousScale: Float? = nil
    
    init(metalDevice: MTLDevice,
         tilePipeline: TilePipeline,
         mapBaseColors: ImmersiveMapBaseColors) {
        self.metalDevice = metalDevice
        self.tilePipeline = tilePipeline
        let backgroundColor = mapBaseColors.getTileBgColor()
        self.pageClearColor = MTLClearColor(red: Double(backgroundColor.x),
                                            green: Double(backgroundColor.y),
                                            blue: Double(backgroundColor.z),
                                            alpha: 1.0)
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = .always
        depthStateDescriptor.isDepthWriteEnabled = false
        self.depthStencilState = metalDevice.makeDepthStencilState(descriptor: depthStateDescriptor)!
        
        let count = 4
        projection = Matrix.orthographicMatrix(left: 0, right: Float(4096 * count), bottom: 0, top: Float(4096 * count), near: -1, far: 1)
    }
    
    func resetFrame() {
        for index in pages.indices {
            pages[index].tileData = []
        }
    }

    func releasePages() {
        guard renderEncoder == nil else { return }
        pages = []
        sharedDepthTexture = nil
    }

    func beginPageEncoding(commandBuffer: MTLCommandBuffer, pageIndex: Int) -> Bool {
        guard pageIndex >= 0 else { return false }
        guard renderEncoder == nil else { return false }

        ensurePage(at: pageIndex)
        pages[pageIndex].tileData = []
        previousShiftX = nil
        previousShiftY = nil
        previousScale = nil

        let page = pages[pageIndex]
        guard let depthTexture = ensureSharedDepthTexture() else { return false }
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = page.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = pageClearColor
        renderPassDescriptor.depthAttachment.texture = depthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 1.0

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return false
        }
        self.renderEncoder = renderEncoder
        activePageIndex = pageIndex
        renderEncoder.setDepthStencilState(depthStencilState)
        return true
    }
    
    func selectTilePipeline() {
        tilePipeline.selectPipeline(renderEncoder: renderEncoder!)
        // Клип по placeIn нужен только flat-пути: в атласе область ячейки
        // уже ограничена scissor-ом, шейдеру передаётся отключённый клип.
        var localClipBounds = TileLocalClipMath.disabledBounds
        renderEncoder!.setFragmentBytes(&localClipBounds,
                                        length: MemoryLayout<SIMD4<Float>>.stride,
                                        index: 1)
    }
    
    func endEncoding() {
        renderEncoder?.endEncoding()
        renderEncoder = nil
        activePageIndex = nil
    }

    func setOverviewFadeAlphas(overviewAlpha: Float, roadAlpha: Float, landuseAlpha: Float) {
        guard let renderEncoder else { return }
        var uniform = TileOverviewFadeUniform(overviewAlpha: overviewAlpha,
                                              roadAlpha: roadAlpha,
                                              landuseAlpha: landuseAlpha)
        renderEncoder.setFragmentBytes(&uniform,
                                       length: MemoryLayout<TileOverviewFadeUniform>.stride,
                                       index: 0)
    }
    
    func draw(allocation: GlobeAtlasAllocation) -> Bool {
        let placeTile = allocation.placeTile
        let placedPos = allocation.placedPosition
        let atlasDepth = allocation.atlasDepth.rawValue
        guard let renderEncoder,
              activePageIndex == allocation.pageIndex,
              pages.indices.contains(allocation.pageIndex) else {
            return false
        }
        
        let placeIn = placeTile.placeIn
        let metalTile = placeTile.metalTile
        let count = 1 << atlasDepth
        if count != previousProjectionCount {
            projection = Matrix.orthographicMatrix(left: 0, right: Float(4096 * count), bottom: 0, top: Float(4096 * count), near: -1, far: 1)
            previousProjectionCount = count
        }
        
        // Add tile metadata for globe placement
        let cellSize = size / count
        let freePtr = Int(placedPos.x) + Int(placedPos.y) * count
        pages[allocation.pageIndex].tileData.append(TileData(position: simd_int1(freePtr),
                                                             textureSize: simd_int1(size),
                                                             cellSize: simd_int1(cellSize),
                                                             tile: simd_int3(Int32(placeIn.x), Int32(placeIn.y), Int32(placeIn.z)),
                                                             sourceTile: simd_int3(Int32(metalTile.tile.x),
                                                                                   Int32(metalTile.tile.y),
                                                                                   Int32(metalTile.tile.z))))
        
        
        let x = Int(placedPos.x)
        let y = Int(placedPos.y)
        let shiftMatrix = Matrix.translationMatrix(x: Float(x) * 4096, y: Float(y) * 4096, z: 0)
        var cameraUniform = CameraUniform(matrix: projection * shiftMatrix,
                                          eye: SIMD3<Float>(0, 0, 1),
                                          padding: 0)

        // Place the tile to cover the required area
        // To do that, scale and translate the tile
        let placeInCount = 1 << placeIn.z
        let zDiff = placeIn.z - metalTile.tile.z
        let scale = powf(2.0, Float(zDiff))
        
        let mtCount = 1 << metalTile.tile.z
        let relX = Float(placeIn.x) - (Float(metalTile.tile.x) * scale)
        let relY = Float(placeIn.y) + (Float((mtCount - 1) - metalTile.tile.y) * scale)
        
        let shiftX = -1.0 * Float(relX) * 4096.0
        let shiftY = -1.0 * Float(Float(placeInCount - 1) - relY) * 4096.0
        if shiftX != previousShiftX || shiftY != previousShiftY || scale != previousScale {
            var modelMatrix = Matrix.translationMatrix(x: shiftX, y: shiftY, z: 0) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            previousShiftX = shiftX
            previousShiftY = shiftY
            previousScale = scale
        }
        
        
        // Draw the tile into the atlas texture (map texture)
        // Set the drawable area
        let scissorRect = MTLScissorRect(
            x: Int(placedPos.x) * cellSize,
            y: ((count - 1) - Int(placedPos.y)) * cellSize,
            width: cellSize,
            height: cellSize
        )
        renderEncoder.setScissorRect(scissorRect)
        renderEncoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        
        // Set tile data for rendering
        let buffers = metalTile.tileBuffers
        renderEncoder.setVertexBuffer(buffers.ground.verticesBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(buffers.ground.stylesBuffer, offset: 0, index: 2)
        renderEncoder.setVertexBuffer(buffers.ground.overviewStyleMaskBuffer, offset: 0, index: 4)

        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: buffers.ground.indicesCount,
                                            indexType: .uint32,
                                            indexBuffer: buffers.ground.indicesBuffer,
                                            indexBufferOffset: 0)
        
        return true
    }

    private func ensurePage(at pageIndex: Int) {
        while pages.count <= pageIndex {
            pages.append(makePage())
        }
    }

    /// Перегенерирует mip-уровни перерисованных страниц; вызывается после
    /// завершения рендер-пассов страниц в том же command buffer.
    func generateMipmaps(commandBuffer: MTLCommandBuffer, pageIndexes: [Int]) {
        guard renderEncoder == nil else { return }
        let mippedPageIndexes = pageIndexes.filter {
            pages.indices.contains($0) && pages[$0].texture.mipmapLevelCount > 1
        }
        guard mippedPageIndexes.isEmpty == false,
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        for pageIndex in mippedPageIndexes {
            blitEncoder.generateMipmaps(for: pages[pageIndex].texture)
        }
        blitEncoder.endEncoding()
    }

    private func makePage() -> Page {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.width = size
        descriptor.height = size
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        descriptor.mipmapLevelCount = Self.pageMipLevelCount

        return Page(texture: metalDevice.makeTexture(descriptor: descriptor)!,
                    tileData: [])
    }

    private func ensureSharedDepthTexture() -> MTLTexture? {
        if let sharedDepthTexture {
            return sharedDepthTexture
        }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                       width: size,
                                                                       height: size,
                                                                       mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        // Симулятор и нативный macOS не работают с memoryless depth для этого рендера
        // в атлас (memoryless - оптимизация tile memory для iOS TBDR GPU).
        #if targetEnvironment(simulator) || os(macOS)
        depthDescriptor.storageMode = .private
        #else
        depthDescriptor.storageMode = metalDevice.supportsFamily(.apple1) ? .memoryless : .private
        #endif
        let texture = metalDevice.makeTexture(descriptor: depthDescriptor)
        texture?.label = "GlobeTilesTextureSharedDepth"
        sharedDepthTexture = texture
        return texture
    }
}
