// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  PoiSpriteAtlas.swift
//  ImmersiveMap
//

import Foundation
import Metal
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import simd

enum PoiSpriteIcon: String, CaseIterable {
    case restaurant
    case cafe
    case bar
    case park
    case museum
    case hospital
    case school
    case airport
    case stadium
    case hotel
    case shopping
    case gasStation
    case pharmacy
    case viewpoint

    fileprivate var symbolNames: [String] {
        switch self {
        case .restaurant:
            return ["fork.knife", "fork.knife.circle.fill", "mappin.circle.fill"]
        case .cafe:
            return ["cup.and.saucer.fill", "mug.fill", "fork.knife"]
        case .bar:
            return ["wineglass.fill", "wineglass", "fork.knife"]
        case .park:
            return ["tree.fill", "leaf.fill", "circle.fill"]
        case .museum:
            return ["building.columns.fill", "building.columns", "building.2.fill"]
        case .hospital:
            return ["cross.case.fill", "cross.case", "cross.fill"]
        case .school:
            return ["graduationcap.fill", "book.fill", "building.columns.fill"]
        case .airport:
            return ["airplane", "airplane.circle.fill", "mappin.circle.fill"]
        case .stadium:
            return ["sportscourt.fill", "figure.soccer", "circle.fill"]
        case .hotel:
            return ["bed.double.fill", "bed.double", "building.2.fill"]
        case .shopping:
            return ["bag.fill", "cart.fill", "basket.fill"]
        case .gasStation:
            return ["fuelpump.fill", "fuelpump", "bolt.car.fill"]
        case .pharmacy:
            return ["pills.fill", "cross.case.fill", "cross.fill"]
        case .viewpoint:
            return ["binoculars.fill", "eye.fill", "location.viewfinder"]
        }
    }
}

struct PoiSpriteAtlasDescriptor {
    let cellSize: Int
    let cellPadding: Int
    let minimumColumns: Int
    #if canImport(UIKit)
    let symbolWeight: UIImage.SymbolWeight
    #endif

    #if canImport(UIKit)
    static let `default` = PoiSpriteAtlasDescriptor(cellSize: 64,
                                                    cellPadding: 8,
                                                    minimumColumns: 4,
                                                    symbolWeight: .semibold)
    #else
    static let `default` = PoiSpriteAtlasDescriptor(cellSize: 64,
                                                    cellPadding: 8,
                                                    minimumColumns: 4)
    #endif
}

struct PoiSpriteAtlasRegion {
    let index: Int
    let pixelRect: CGRect
    let uvRect: SIMD4<Float>
}

struct PoiSpriteAtlasLayout {
    let icons: [PoiSpriteIcon]
    let descriptor: PoiSpriteAtlasDescriptor
    let cellsPerSide: Int
    let pixelSize: Int

    private let regionsByIcon: [PoiSpriteIcon: PoiSpriteAtlasRegion]

    init(icons: [PoiSpriteIcon] = PoiSpriteIcon.allCases,
         descriptor: PoiSpriteAtlasDescriptor = .default) {
        precondition(icons.isEmpty == false, "POI sprite atlas requires at least one icon.")
        precondition(descriptor.cellSize > descriptor.cellPadding * 2,
                     "POI sprite atlas padding must leave drawable pixels inside each cell.")

        self.icons = icons
        self.descriptor = descriptor

        let requiredSide = Int(ceil(sqrt(Double(icons.count))))
        self.cellsPerSide = max(descriptor.minimumColumns, requiredSide)
        self.pixelSize = self.cellsPerSide * descriptor.cellSize

        let invSize = 1.0 / Float(pixelSize)
        var regions: [PoiSpriteIcon: PoiSpriteAtlasRegion] = [:]
        regions.reserveCapacity(icons.count)

        for (index, icon) in icons.enumerated() {
            let cellX = index % cellsPerSide
            let cellY = index / cellsPerSide
            let pixelRect = CGRect(x: cellX * descriptor.cellSize,
                                   y: cellY * descriptor.cellSize,
                                   width: descriptor.cellSize,
                                   height: descriptor.cellSize)
            let uvRect = SIMD4<Float>(Float(pixelRect.minX) * invSize,
                                      Float(pixelRect.minY) * invSize,
                                      Float(pixelRect.maxX) * invSize,
                                      Float(pixelRect.maxY) * invSize)
            regions[icon] = PoiSpriteAtlasRegion(index: index,
                                                 pixelRect: pixelRect,
                                                 uvRect: uvRect)
        }

        self.regionsByIcon = regions
    }

    func region(for icon: PoiSpriteIcon) -> PoiSpriteAtlasRegion? {
        regionsByIcon[icon]
    }
}

final class PoiSpriteAtlas {
    let descriptor: PoiSpriteAtlasDescriptor
    let layout: PoiSpriteAtlasLayout
    let bitmapImage: CGImage
    let texture: MTLTexture

    init(device: MTLDevice,
         icons: [PoiSpriteIcon] = PoiSpriteIcon.allCases,
         descriptor: PoiSpriteAtlasDescriptor = .default) {
        self.descriptor = descriptor
        self.layout = PoiSpriteAtlasLayout(icons: icons, descriptor: descriptor)
        self.bitmapImage = Self.makeBitmapImage(layout: layout, descriptor: descriptor)
        self.texture = Self.makeTexture(device: device, image: bitmapImage)
        if self.texture.label == nil {
            self.texture.label = RenderResourceName.poiSpriteAtlas.rawValue
        }
    }

    func region(for icon: PoiSpriteIcon) -> PoiSpriteAtlasRegion? {
        layout.region(for: icon)
    }

    static func makeBitmapImage(layout: PoiSpriteAtlasLayout,
                                descriptor: PoiSpriteAtlasDescriptor = .default) -> CGImage {
        let size = CGSize(width: layout.pixelSize, height: layout.pixelSize)
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            cgContext.clear(CGRect(origin: .zero, size: size))
            cgContext.interpolationQuality = .high
            UIColor.white.setFill()

            for icon in layout.icons {
                guard let region = layout.region(for: icon) else { continue }
                drawIcon(icon,
                         in: region.pixelRect.insetBy(dx: CGFloat(descriptor.cellPadding),
                                                      dy: CGFloat(descriptor.cellPadding)),
                         descriptor: descriptor,
                         context: cgContext)
            }
        }

        guard let cgImage = image.cgImage else {
            fatalError("Failed to rasterize POI sprite atlas image.")
        }
        return cgImage
        #else
        return makeFallbackBitmapImage(size: size,
                                       layout: layout,
                                       descriptor: descriptor)
        #endif
    }

    private static func makeFallbackBitmapImage(size: CGSize,
                                                layout: PoiSpriteAtlasLayout,
                                                descriptor: PoiSpriteAtlasDescriptor) -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)

        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little
                                            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
                                            .rawValue) else {
                return nil
            }

            context.clear(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            for icon in layout.icons {
                guard let region = layout.region(for: icon) else { continue }
                let rect = region.pixelRect.insetBy(dx: CGFloat(descriptor.cellPadding),
                                                    dy: CGFloat(descriptor.cellPadding))
                context.fillEllipse(in: rect.insetBy(dx: rect.width * 0.18,
                                                     dy: rect.height * 0.18))
            }
            return context.makeImage()
        }

        guard let image else {
            fatalError("Failed to rasterize fallback POI sprite atlas image.")
        }
        return image
    }

    private static func makeTexture(device: MTLDevice, image: CGImage) -> MTLTexture {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create POI sprite atlas texture.")
        }

        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let alphaInfo = CGImageAlphaInfo.premultipliedFirst
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: alphaInfo.rawValue))
            guard let context = CGContext(data: baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo.rawValue)
            else {
                return
            }

            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: bytesPerRow)
        }
        return texture
    }

    private static func drawIcon(_ icon: PoiSpriteIcon,
                                 in rect: CGRect,
                                 descriptor: PoiSpriteAtlasDescriptor,
                                 context: CGContext) {
        #if canImport(UIKit)
        let iconRect = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.16)
        let pointSize = min(iconRect.width, iconRect.height)
        guard let symbolImage = makeSymbolImage(for: icon,
                                                pointSize: pointSize,
                                                weight: descriptor.symbolWeight) else {
            return
        }

        let targetRect = aspectFitRect(contentSize: symbolImage.size, in: iconRect)
        symbolImage.draw(in: targetRect)
        #endif
    }

    #if canImport(UIKit)
    private static func makeSymbolImage(for icon: PoiSpriteIcon,
                                        pointSize: CGFloat,
                                        weight: UIImage.SymbolWeight) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize,
                                                        weight: weight,
                                                        scale: .large)
        for symbolName in icon.symbolNames {
            if let image = UIImage(systemName: symbolName, withConfiguration: configuration) {
                return image.withTintColor(.white, renderingMode: .alwaysOriginal)
            }
        }
        return nil
    }
    #endif

    private static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return bounds
        }

        let widthScale = bounds.width / contentSize.width
        let heightScale = bounds.height / contentSize.height
        let scale = min(widthScale, heightScale)

        let fittedSize = CGSize(width: contentSize.width * scale,
                                height: contentSize.height * scale)
        return CGRect(x: bounds.midX - (fittedSize.width * 0.5),
                      y: bounds.midY - (fittedSize.height * 0.5),
                      width: fittedSize.width,
                      height: fittedSize.height)
    }
}
