// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Credentials for the two tile services under measurement. The environment
/// wins; otherwise the gitignored `LocalSecrets.plist` at the repository root
/// is read, live off the checkout where the process can see it (simulator)
/// and from the copy the "Bundle LocalSecrets" build phase put into the app
/// bundle on a physical device. Nothing here is ever committed.
enum BenchSecrets {
    static let immersiveMapTileTemplate = "https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt"

    static func immersiveMapHeaders() -> [String: String] {
        guard let key = value(forKey: "IMMERSIVEMAP_API_KEY") else { return [:] }
        return ["Authorization": "Bearer \(key)"]
    }

    static func mapboxAccessToken() -> String? {
        value(forKey: "MAPBOX_ACCESS_TOKEN")
    }

    private static func value(forKey key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], value.isEmpty == false {
            return value
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                let secrets = directory.appendingPathComponent("LocalSecrets.plist")
                if let value = NSDictionary(contentsOf: secrets)?[key] as? String, value.isEmpty == false {
                    return value
                }
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        guard let bundled = Bundle.main.url(forResource: "LocalSecrets", withExtension: "plist") else {
            return nil
        }
        let value = NSDictionary(contentsOf: bundled)?[key] as? String
        return (value?.isEmpty == false) ? value : nil
    }
}
