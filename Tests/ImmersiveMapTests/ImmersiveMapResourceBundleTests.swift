// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The lookup of the engine's resource bundle in an app
/// (`ImmersiveMapResourceBundle`): the bundle in the app's
/// `Contents/Resources` and nowhere else, and an app without it an error,
/// never `Bundle.module` with its build folder. The fake apps are folders in
/// the temporary directory, laid out as a macOS app is.
final class ImmersiveMapResourceBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImmersiveMapResourceBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The case of an app built with `swift build` and wrapped by a script:
    /// the bundle copied into `Contents/Resources`.
    func testABundleInAFakeAppsResourcesIsFound() throws {
        let app = try makeApp(named: "Editor")
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let placed = resources.appendingPathComponent(ImmersiveMapResourceBundle.bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: placed, withIntermediateDirectories: true)
        let appBundle = try XCTUnwrap(Bundle(url: app))

        let found = try ImmersiveMapResourceBundle.locate(mainBundle: appBundle,
                                                          moduleBundle: Self.moduleBundleNeverAsked).get()

        XCTAssertEqual(found.bundleURL.resolvingSymlinksInPath(), placed.resolvingSymlinksInPath())
    }

    /// An app without the bundle in its resources gets the error, and the
    /// build folder's bundle behind `Bundle.module` is never asked for.
    func testAnAppWithoutTheBundleGetsTheErrorAndNotTheBuildFoldersBundle() throws {
        let app = try makeApp(named: "Empty")
        let appBundle = try XCTUnwrap(Bundle(url: app))

        switch ImmersiveMapResourceBundle.locate(mainBundle: appBundle,
                                                 moduleBundle: Self.moduleBundleNeverAsked) {
        case .success(let bundle):
            XCTFail("found \(bundle.bundlePath) in an app that holds none")
        case .failure(let error):
            XCTAssertEqual(error.searchedDirectory.resolvingSymlinksInPath(),
                           app.appendingPathComponent("Contents/Resources").resolvingSymlinksInPath())
            XCTAssertTrue(error.localizedDescription.contains(ImmersiveMapResourceBundle.bundleName))
        }
    }

    /// Stands for `Bundle.module`, which an app must never reach.
    private static func moduleBundleNeverAsked() -> Bundle {
        XCTFail("Bundle.module was asked in an app")
        return Bundle(for: ImmersiveMapResourceBundleTests.self)
    }

    /// An app bundle as macOS lays one out: an Info.plist, an executable
    /// and an empty resources folder.
    private func makeApp(named name: String) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: contents.appendingPathComponent("Resources", isDirectory: true),
                                        withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.immersivemap.tests.\(name.lowercased())",
                                   "CFBundleExecutable": name,
                                   "CFBundleName": name,
                                   "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: contents.appendingPathComponent("MacOS/\(name)"))
        return app
    }
}
