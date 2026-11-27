// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// The eviction of a cache that is a directory of files: the files used
/// longest ago go first, until the directory fits its quota. A file's
/// modification date is its "used" stamp, which the cache's owner renews
/// when it reads the file.
enum DiskCacheTrim {
    struct File {
        let url: URL
        let byteCount: Int
        let used: Date
    }

    /// The files of `directory`, the one used longest ago first. With a
    /// `pathExtension` only the files of that extension are the cache's.
    static func files(in directory: URL, pathExtension: String? = nil) -> [File] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url -> File? in
            if let pathExtension, url.pathExtension != pathExtension {
                return nil
            }
            guard let values = try? url.resourceValues(forKeys: keys), let byteCount = values.fileSize else {
                return nil
            }
            return File(url: url, byteCount: byteCount, used: values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.used < $1.used }
    }

    /// Removes the files used longest ago until what is left fits `quota`.
    static func trim(directory: URL, toByteCount quota: Int, pathExtension: String? = nil) {
        let files = files(in: directory, pathExtension: pathExtension)
        var total = files.reduce(0) { $0 + $1.byteCount }
        for file in files where total > quota {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.byteCount
        }
    }
}
