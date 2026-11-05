// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The engine's resource bundle, `ImmersiveMap_ImmersiveMap.bundle`: the
/// shader library (`default.metallib`), the text atlases, the avatar marker,
/// the overview archive and the tree model. Every read of an engine resource
/// goes through `bundle()`, never through `Bundle.module` directly.
///
/// The resources always travel with the engine in this one bundle, and in an
/// app the bundle is always inside the app. So the lookup has one rule:
///
/// - In an app (the main bundle is an `.app`): the bundle in the app's
///   resources, `Contents/Resources` on macOS, and nowhere else. An app
///   without it gets `NotFound`.
/// - In a program that is no app (the engine's tests, a command-line tool),
///   where SwiftPM puts the bundle beside the executable: `Bundle.module`.
///
/// `Bundle.module` is never asked in an app. SwiftPM's command line
/// generates it to look beside the app's `Contents`, where code signing
/// allows nothing, and then at the absolute path of the build folder it
/// compiles into the binary. An app built with `swift build` and wrapped by
/// a script would read the engine's resources from the developer's disk,
/// and stop on any other Mac when `Bundle.module` finds nothing.
enum ImmersiveMapResourceBundle {
    /// The bundle's folder name, the one SwiftPM and Xcode both give it.
    static let bundleName = "ImmersiveMap_ImmersiveMap.bundle"

    /// The app holds no engine resource bundle in its resources.
    struct NotFound: Error, Equatable, CustomStringConvertible, LocalizedError {
        /// The folder the bundle was looked for in: the app's resources.
        let searchedDirectory: URL

        var description: String {
            "The map's resource bundle \(ImmersiveMapResourceBundle.bundleName) is not in the app's resources at \(searchedDirectory.path)."
        }

        var errorDescription: String? { description }
    }

    /// The engine's resource bundle, located once per process.
    static func bundle() throws -> Bundle {
        try located.get()
    }

    private static let located: Result<Bundle, NotFound> = locate(mainBundle: .main,
                                                                  moduleBundle: { Bundle.module })

    /// The rule of the type's comment, for a main bundle. `moduleBundle` is
    /// asked only when the main bundle is no app.
    static func locate(mainBundle: Bundle, moduleBundle: () -> Bundle) -> Result<Bundle, NotFound> {
        guard isApp(mainBundle) else {
            return .success(moduleBundle())
        }
        let resources = mainBundle.resourceURL ?? mainBundle.bundleURL
        let url = resources.appendingPathComponent(bundleName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           let bundle = Bundle(url: url) {
            return .success(bundle)
        }
        return .failure(NotFound(searchedDirectory: resources))
    }

    /// Whether the bundle is an application's, on macOS or on iOS.
    static func isApp(_ bundle: Bundle) -> Bool {
        bundle.bundleURL.pathExtension == "app"
    }
}
