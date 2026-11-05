// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import PackagePlugin

/// Compiles every `.metal` file of the target into one `default.metallib`,
/// which the build adds to the target's resource bundle, whoever builds the
/// package: Xcode, `swift build`, `swift test`.
///
/// The shaders are not resources of the target (Package.swift excludes
/// them). As resources, Xcode compiled them into the bundle's library and
/// SwiftPM's command line copied the sources there uncompiled, so an app
/// built with `swift build` had no library to draw with. Here one build
/// command runs `xcrun metal` over every shader at once, compiling and
/// linking in one call, and nothing else makes a library, so every build
/// ends with the same single `default.metallib`.
///
/// The command is `compile-metal-library.sh`, beside this file, which picks
/// the platform from the build settings Xcode sets in the command's
/// environment and takes macOS under SwiftPM's command line. It is a file
/// and not an inline `sh -c` script because Xcode splits a build command's
/// argument at its newlines and expands `$(...)` in it as a build setting.
///
/// The inputs are the shaders and every header of the target, so a change
/// to an included header rebuilds the library.
@main
struct MetalLibraryPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let targetDirectory = target.directoryURL
        let shaders = Self.files(in: targetDirectory, withExtension: "metal")
        guard shaders.isEmpty == false else {
            return []
        }
        let headers = Self.files(in: targetDirectory, withExtension: "h")
        let workDirectory = context.pluginWorkDirectoryURL
        let script = context.package.directoryURL
            .appendingPathComponent("Plugins/MetalLibraryPlugin/compile-metal-library.sh")
        let library = workDirectory.appendingPathComponent("MetalLibrary/default.metallib")
        let moduleCache = workDirectory.appendingPathComponent("MetalModuleCache")
        return [
            .buildCommand(displayName: "Compiling \(shaders.count) Metal shaders of \(target.name) into default.metallib",
                          executable: URL(fileURLWithPath: "/bin/sh"),
                          arguments: [script.path, library.path, moduleCache.path] + shaders.map(\.path),
                          inputFiles: [script] + shaders + headers,
                          outputFiles: [library])
        ]
    }

    /// Every file of the extension under the directory, in a stable order.
    private static func files(in directory: URL, withExtension pathExtension: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == pathExtension }
            .sorted { $0.path < $1.path }
    }
}
