// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import zlib

/// The gzip step for directories and tiles. zlib rather than the Compression
/// framework because the latter speaks raw deflate only: the gzip member
/// header with its optional name and comment fields, the CRC and the size
/// trailer would all be ours to parse. `inflateInit2` with window bits 15+32
/// reads gzip and zlib wrapping alike and verifies the trailer.
package enum PMTilesGzip {
    /// A directory or a tile larger than this is a corrupt length, not data.
    package static let maximumOutputByteCount = 64 * 1024 * 1024

    /// Returns `data` unchanged for `.none`, inflates it for `.gzip`. Any
    /// other compression was rejected by the header parser already.
    package static func decompress(_ data: Data, compression: PMTilesCompression) throws -> Data {
        switch compression {
        case .none:
            return data
        case .gzip:
            return try inflate(data)
        case .unknown, .brotli, .zstd:
            throw PMTilesFormatError.unsupportedCompression(compression.rawValue)
        }
    }

    package static func inflate(_ data: Data, expectedByteCount: Int? = nil) throws -> Data {
        guard data.isEmpty == false else {
            return Data()
        }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw PMTilesFormatError.corruptCompressedData
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = max(16 * 1024, min(Self.maximumOutputByteCount, expectedByteCount ?? data.count * 4))
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var input = [UInt8](data)

        var status: Int32 = Z_OK
        try input.withUnsafeMutableBufferPointer { inputBuffer in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = UInt32(inputBuffer.count)
            repeat {
                try chunk.withUnsafeMutableBufferPointer { chunkBuffer in
                    stream.next_out = chunkBuffer.baseAddress
                    stream.avail_out = UInt32(chunkBuffer.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    switch status {
                    case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
                        break
                    default:
                        throw PMTilesFormatError.corruptCompressedData
                    }
                    let produced = chunkBuffer.count - Int(stream.avail_out)
                    if produced > 0 {
                        guard output.count + produced <= Self.maximumOutputByteCount else {
                            throw PMTilesFormatError.decompressedDataTooLarge
                        }
                        output.append(chunkBuffer.baseAddress!, count: produced)
                    }
                }
                // Z_BUF_ERROR with no input left and nothing produced is a
                // truncated stream: the trailer never came.
                if status == Z_BUF_ERROR, stream.avail_in == 0 {
                    throw PMTilesFormatError.corruptCompressedData
                }
            } while status != Z_STREAM_END
        }
        return output
    }
}
