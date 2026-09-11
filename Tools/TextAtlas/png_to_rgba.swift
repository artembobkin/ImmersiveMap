// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Unpacks a PNG into the raw pixel file the engine's text renderer uploads
// as is: BGRA8 (the byte order of Metal's bgra8Unorm), row major, top row
// first, four bytes per pixel, no header. The bytes are exactly what
// MTKTextureLoader used to upload from the PNG (a bgra8Unorm texture with
// straight, unpremultiplied coverage in every channel), which is why the
// loader does the decoding here rather than CoreGraphics, whose contexts
// premultiply. Used by generate_text_atlas.sh, which compiles it on the fly:
//
//   swiftc -O -o png_to_rgba png_to_rgba.swift
//   ./png_to_rgba atlas.png atlas.bgra

import Foundation
import Metal
import MetalKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: png_to_rgba <in.png> <out.bgra>\n".utf8))
    exit(1)
}
guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write(Data("png_to_rgba: Metal is not available\n".utf8))
    exit(1)
}
let loader = MTKTextureLoader(device: device)
let options: [MTKTextureLoader.Option: Any] = [
    .SRGB: false,
    .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)
]
do {
    let texture = try loader.newTexture(URL: URL(fileURLWithPath: arguments[1]), options: options)
    guard texture.pixelFormat == .bgra8Unorm else {
        FileHandle.standardError.write(Data("png_to_rgba: expected bgra8Unorm, got \(texture.pixelFormat.rawValue)\n".utf8))
        exit(1)
    }
    var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(&pixels,
                     bytesPerRow: texture.width * 4,
                     from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                     mipmapLevel: 0)
    try Data(pixels).write(to: URL(fileURLWithPath: arguments[2]))
    print("\(texture.width)x\(texture.height), \(pixels.count) bytes")
} catch {
    FileHandle.standardError.write(Data("png_to_rgba: \(error)\n".utf8))
    exit(1)
}
