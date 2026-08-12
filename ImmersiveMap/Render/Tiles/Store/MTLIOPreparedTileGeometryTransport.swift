// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// File transport for prepared-tile geometry blobs on Metal 3 devices: the
/// blob is written next to the metadata (an MTLIO compression container with
/// LZFSE chunks, or the raw arena bytes when prepared-disk compression is
/// disabled), and a cache hit loads it straight into the tile's arena buffer
/// through `MTLIOCommandQueue`, so the bulk bytes of a warm tile never pass
/// through a CPU decode.
struct MTLIOPreparedTileGeometryTransport: PreparedTileGeometryTransporting {
    let cacheNamespaceMarker = "bio"
    /// `preparedDiskCompressionEnabled`: this transport is where the setting
    /// reaches the bytes that dominate an entry, not just the metadata
    /// envelope. Off means `stageBlobFile` writes the raw arena (no LZFSE
    /// pass on save, no decompression stage in the load) at the cost of
    /// larger cache files, exactly the trade the setting documents.
    let compressionEnabled: Bool

    init(compressionEnabled: Bool) {
        self.compressionEnabled = compressionEnabled
    }

    var blobTransport: PreparedTileGeometryBlobTransport {
        .file(compressionEnabled ? .lzfseContainer : .raw)
    }

    /// MTLIO compression containers are written strictly one at a time,
    /// process-wide. Before v31 that serialization fell out of running the
    /// writes on the shared cache IO queue; this queue keeps the one-writer
    /// pattern (the only one v30 ever exercised against the IOGPU driver)
    /// without putting the CPU work back where cache reads would wait
    /// behind it.
    private static let containerWriteQueue = DispatchQueue(
        label: "ImmersiveMap.MTLIOPreparedTileGeometryTransport.containerWrite",
        qos: .utility
    )

    /// The simulator lacks the MTLIO fast path and Intel Macs lack Metal 3;
    /// both fall back to the inline transport. The full capability decision
    /// belongs to `MetalTileFactory.loadsFileBlobs`, which also covers IO
    /// command queue creation; this static check only gates test scenarios.
    static func isSupported(metalDevice: MTLDevice) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return metalDevice.supportsFamily(.metal3)
        #endif
    }

    func stageBlobFile(_ blob: Data, near url: URL) throws -> URL {
#if targetEnvironment(simulator)
        // Unreachable: the factory never selects this transport on the
        // simulator, whose SDK carries no MTLIO surface to compile against.
        _ = blob
        _ = url
        assertionFailure("The MTLIO transport is never selected on the simulator")
        throw PreparedTileDiskCodecError.invalidField("MTLIOPreparedTileGeometryTransport.stageBlobFile")
#else
        let stagedURL = makeStagingURL(near: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if compressionEnabled {
            try Self.containerWriteQueue.sync {
                guard let context = MTLIOCreateCompressionContext(stagedURL.path,
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
                    try? FileManager.default.removeItem(at: stagedURL)
                    throw PreparedTileDiskCodecError.corruptedPayload("Could not write the MTLIO compression container.")
                }
            }
        } else {
            do {
                try blob.write(to: stagedURL)
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                throw error
            }
        }
        return stagedURL
#endif
    }

    func commitStagedBlobFile(at stagedURL: URL, to url: URL) throws {
#if targetEnvironment(simulator)
        _ = stagedURL
        _ = url
        assertionFailure("The MTLIO transport is never selected on the simulator")
        throw PreparedTileDiskCodecError.invalidField("MTLIOPreparedTileGeometryTransport.commitStagedBlobFile")
#else
        try replaceFile(at: url, withStagedFileAt: stagedURL)
#endif
    }
}
