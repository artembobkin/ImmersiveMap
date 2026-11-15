// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  PinSDFResource.swift
//  ImmersiveMap
//

import Foundation
import Metal
import MetalKit

struct PinSDFParams {
    var distanceRangeTexels: Float
}

struct PinSDFShapeMetrics {
    var pointerHeightRatio: Float
}

private struct PinSDFMetadata: Decodable {
    let schemaVersion: Int
    let distanceRangeTexels: Float
    let imageWidth: Int
    let imageHeight: Int
    let pointerHeightRatio: Float
}

enum PinSDFResourceError: Error {
    case missingTextureResource(String)
    case missingMetadataResource(String)
    case failedToLoadTexture(URL, Error)
    case failedToDecodeMetadata(URL, Error)
    case incompatibleMetadataSchema(Int)
    case metadataTextureSizeMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
}

final class PinSDFResource {
    static let baseName = "pin_sdf"
    static let supportedSchemaVersion = 1

    let texture: MTLTexture
    let params: PinSDFParams
    let shapeMetrics: PinSDFShapeMetrics

    /// `bundle` is the engine's resource bundle (`ImmersiveMapResourceBundle`).
    init(device: MTLDevice,
         bundle: Bundle) throws {
        let textureURL = try Self.textureURL(in: bundle)
        let metadataURL = try Self.metadataURL(in: bundle)

        let textureLoader = MTKTextureLoader(device: device)
        do {
            self.texture = try textureLoader.newTexture(URL: textureURL,
                                                        options: [
                                                            .SRGB: false
                                                        ])
        } catch {
            throw PinSDFResourceError.failedToLoadTexture(textureURL, error)
        }

        let metadata: PinSDFMetadata
        do {
            let data = try Data(contentsOf: metadataURL)
            metadata = try JSONDecoder().decode(PinSDFMetadata.self, from: data)
        } catch {
            throw PinSDFResourceError.failedToDecodeMetadata(metadataURL, error)
        }

        guard metadata.schemaVersion == Self.supportedSchemaVersion else {
            throw PinSDFResourceError.incompatibleMetadataSchema(metadata.schemaVersion)
        }
        guard metadata.imageWidth == texture.width,
              metadata.imageHeight == texture.height else {
            throw PinSDFResourceError.metadataTextureSizeMismatch(expectedWidth: metadata.imageWidth,
                                                                          expectedHeight: metadata.imageHeight,
                                                                          actualWidth: texture.width,
                                                                          actualHeight: texture.height)
        }

        self.params = PinSDFParams(distanceRangeTexels: metadata.distanceRangeTexels)
        self.shapeMetrics = PinSDFShapeMetrics(pointerHeightRatio: metadata.pointerHeightRatio)
    }

    private static func textureURL(in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: baseName, withExtension: "png") else {
            throw PinSDFResourceError.missingTextureResource("\(baseName).png")
        }
        return url
    }

    private static func metadataURL(in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: baseName, withExtension: "json") else {
            throw PinSDFResourceError.missingMetadataResource("\(baseName).json")
        }
        return url
    }
}
