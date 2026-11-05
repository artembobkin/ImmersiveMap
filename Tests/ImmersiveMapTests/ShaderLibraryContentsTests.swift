// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// The shader library the build puts in the engine's resource bundle
/// (`MetalLibraryPlugin`): one `default.metallib`, whoever built the
/// package, holding every entry point the shaders declare and every
/// function the renderer asks for by a literal name. And a library that
/// cannot be had is an error the map reports, not a stop.
final class ShaderLibraryContentsTests: XCTestCase {
    /// The library file is in the bundle, read without the main bundle's
    /// fallback, and holds what the sources declare and the code names.
    func testTheBuiltBundleHoldsTheLibraryWithEveryFunctionTheRendererAsksFor() throws {
        let bundle = try ImmersiveMapResourceBundle.bundle()
        let libraryURL = try XCTUnwrap(bundle.url(forResource: "default", withExtension: "metallib"),
                                       "the resource bundle holds default.metallib")
        XCTAssertNil(bundle.url(forResource: "Tile", withExtension: "metal"),
                     "the shaders are compiled into the library, not copied as sources")

        let device = try MetalTestEnvironment.requireDevice()
        let library = try device.makeLibrary(URL: libraryURL)
        let functions = Set(library.functionNames)

        let declared = try Self.declaredEntryPoints()
        XCTAssertGreaterThan(declared.count, 60, "the shader sources were found and read")
        XCTAssertEqual(declared.subtracting(functions), [], "entry points declared in the shaders but missing from the library")

        let named = try Self.literalFunctionNames()
        XCTAssertGreaterThan(named.count, 30, "the Swift sources were found and read")
        XCTAssertEqual(named.subtracting(functions), [], "functions the renderer asks for by name but missing from the library")
        XCTAssertTrue(functions.contains(RendererSetup.engineFunctionName))
    }

    /// A bundle with no library, in a process whose main bundle has none of
    /// the engine's shaders: an error that names the bundle, thrown.
    func testALibraryMissingFromTheBundleIsAnErrorAndNotACrash() throws {
        let device = try MetalTestEnvironment.requireDevice()
        if device.makeDefaultLibrary()?.functionNames.contains(RendererSetup.engineFunctionName) == true {
            throw XCTSkip("this process's main bundle holds the engine's shaders, the fallback would succeed")
        }
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShaderLibraryContentsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(ImmersiveMapResourceBundle.bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty.deletingLastPathComponent()) }
        let bundle = try XCTUnwrap(Bundle(url: empty))

        XCTAssertThrowsError(try RendererSetup.makeLibrary(metalDevice: device, bundle: bundle)) { error in
            guard case let .shaderLibraryUnavailable(bundlePath, _) = error as? RenderResourcesError else {
                return XCTFail("expected the shader library error, got \(error)")
            }
            XCTAssertEqual(URL(fileURLWithPath: bundlePath).lastPathComponent, ImmersiveMapResourceBundle.bundleName)
        }
    }

    // MARK: - The sources

    private static var engineSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ImmersiveMap", isDirectory: true)
    }

    /// Every `vertex`, `fragment` and `kernel` function of the shaders. Each
    /// is declared on one line, its name before its parameter list.
    private static func declaredEntryPoints() throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"^\s*(?:vertex|fragment|kernel)\b[^(]*?\b(\w+)\s*\("#,
                                              options: [.anchorsMatchLines])
        return try matches(of: pattern, inFilesWithExtension: "metal")
    }

    /// The names the Swift sources hand `makeFunction(name:)` as literals.
    private static func literalFunctionNames() throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"makeFunction\(name:\s*"(\w+)""#)
        return try matches(of: pattern, inFilesWithExtension: "swift")
    }

    private static func matches(of pattern: NSRegularExpression,
                                inFilesWithExtension pathExtension: String) throws -> Set<String> {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: engineSources,
                                                                      includingPropertiesForKeys: nil))
        var names: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let name = Range(match.range(at: 1), in: text) {
                    names.insert(String(text[name]))
                }
            }
        }
        return names
    }
}
