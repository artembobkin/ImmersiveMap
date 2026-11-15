// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// The meshes of the layers, kept on disk as the GPU takes them
/// (`LayerMeshFile`). A layer is built from its source once on a device:
/// afterwards its mesh is loaded from here, and the source is neither read
/// nor triangulated. A mesh goes by what it was made of: its source's
/// identity (`LayerSourceIdentity`: a file as it is on disk, or the
/// identity the app gave to data it handed over, under the source's name),
/// the styles baked into it, and the format's version, so a changed source
/// or a changed style is another entry. The data itself is never hashed.
/// The entries used least recently are deleted over `limitBytes`.
///
/// Thread-safe: the files are written and read from the layers' build
/// tasks, and the trimming is serialized by `lock`.
final class LayerMeshDiskCache: @unchecked Sendable {
    static let directoryName = "MapLayerMeshes"
    static let fileExtension = "layermesh"

    let directory: URL
    let limitBytes: Int
    private let lock = NSLock()

    /// A cache under the app's Caches directory, or under `baseDirectory`.
    /// A limit of zero keeps nothing.
    init(limitBytes: Int, baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent(Self.directoryName, isDirectory: true)
        self.limitBytes = max(limitBytes, 0)
    }

    var isEnabled: Bool { limitBytes > 0 }

    /// The entry's file name for a layer drawing the source `identity`
    /// names (`key.source` is the name it is registered under), nil for a
    /// file that cannot be looked at. The name is made of the identity and
    /// the styles, never of the data.
    func entryName(identity: LayerSourceIdentity, key: LayerMeshKey) -> String? {
        var hasher = StableFNV1aHasher()
        hasher.combine(UInt64(LayerMeshFile.version))
        hasher.combine(UInt64(LayerMeshBuilder.chunkZoom))
        hasher.combine(LayerMeshBuilder.maximumEdgeLength.bitPattern)
        switch identity {
        case .file(let sourceURL):
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else {
                return nil
            }
            hasher.combine("file")
            hasher.combine(sourceURL.standardizedFileURL.path)
            hasher.combine(size.uint64Value)
            hasher.combine(modified.timeIntervalSinceReferenceDate.bitPattern)
        case .named(let name):
            hasher.combine("named")
            hasher.combine(key.source)
            // A separator no name holds, so "a" under "bc" is not "ab"
            // under "c".
            hasher.combine(UInt64.max)
            hasher.combine(name)
        }
        func add(_ color: SIMD4<Float>) {
            for index in 0 ..< 4 {
                hasher.combine(UInt64(color[index].bitPattern))
            }
        }
        add(key.polygonStyle.fillColor)
        add(key.polygonStyle.strokeColor)
        hasher.combine(UInt64(key.polygonStyle.strokeWidthPoints.bitPattern))
        add(key.polylineStyle.color)
        hasher.combine(UInt64(key.polylineStyle.widthPoints.bitPattern))
        add(key.pointStyle.color)
        hasher.combine(UInt64(key.pointStyle.radiusPoints.bitPattern))
        add(key.pointStyle.strokeColor)
        hasher.combine(UInt64(key.pointStyle.strokeWidthPoints.bitPattern))
        return String(hasher.finalize(), radix: 16) + "." + Self.fileExtension
    }

    /// The entry's file when the cache holds it, marked as used now.
    func existingFile(named name: String) -> URL? {
        guard isEnabled else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Keeps `data` under `name`, then deletes the entries used least
    /// recently while the cache is over its limit. A mesh larger than the
    /// limit is not kept.
    func store(_ data: Data, named name: String) {
        guard isEnabled, data.count <= limitBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return
        }
        trim()
    }

    func remove(named name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// The entries, the one used longest ago first.
    func entries() -> [(url: URL, size: Int, used: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url -> (url: URL, size: Int, used: Date)? in
            guard url.pathExtension == Self.fileExtension,
                  let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize, let used = values.contentModificationDate else {
                return nil
            }
            return (url, size, used)
        }
        .sorted { $0.used < $1.used }
    }

    private func trim() {
        let entries = entries()
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > limitBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
