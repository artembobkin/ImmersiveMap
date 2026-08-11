// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// File transport for prepared-tile geometry blobs on Metal 3 devices: the
/// blob is written as an MTLIO compression container (LZFSE chunks) next to
/// the metadata, and a cache hit loads it straight into the tile's arena
/// buffer through `MTLIOCommandQueue` with hardware-path decompression, so
/// the bulk bytes of a warm tile never pass through a CPU decode.
struct MTLIOPreparedTileGeometryTransport: PreparedTileGeometryTransporting {
    let cacheNamespaceMarker = "bio"
    let writesBlobFiles = true

    /// The simulator lacks the MTLIO fast path and Intel Macs lack Metal 3;
    /// both fall back to the inline transport.
    static func isSupported(metalDevice: MTLDevice) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return metalDevice.supportsFamily(.metal3)
        #endif
    }

    func writeBlobFile(_ blob: Data, to url: URL) throws {
#if targetEnvironment(simulator)
        // Unreachable: isSupported gates this transport off the simulator,
        // whose SDK carries no MTLIO surface to compile against.
        _ = blob
        _ = url
        assertionFailure("The MTLIO transport is never selected on the simulator")
        throw PreparedTileDiskCodecError.invalidField("MTLIOPreparedTileGeometryTransport.writeBlobFile")
#else
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        guard let context = MTLIOCreateCompressionContext(temporaryURL.path,
                                                          .lzfse,
                                                          MTLIOCompressionContextDefaultChunkSize()) else {
            throw PreparedTileDiskCodecError.corruptedPayload("Could not open the MTLIO compression context.")
        }
        blob.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress, bytes.count > 0 {
                MTLIOCompressionContextAppendData(context, baseAddress, bytes.count)
            }
        }
        guard MTLIOFlushAndDestroyCompressionContext(context) == .complete else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw PreparedTileDiskCodecError.corruptedPayload("Could not write the MTLIO compression container.")
        }

        // Atomic swap into place: `replaceItemAt` needs an existing original,
        // so the first save of a tile moves the temp file instead. Readers
        // that already opened the previous container keep its inode; the next
        // open sees the new one. Writes are serialized per cache root, so the
        // exists check cannot race another writer of the same tile.
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
#endif
    }
}
