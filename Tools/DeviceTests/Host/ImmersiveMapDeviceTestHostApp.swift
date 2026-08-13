// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI

/// The application the device test bundle is injected into.
///
/// A unit test bundle cannot run on an iPhone the way `swift test` runs it on a
/// Mac. SwiftPM test targets are tool-hosted, and `xcodebuild` refuses a device
/// destination for them ("Tool-hosted testing is unavailable on device
/// destinations"): on iOS a test bundle has to be loaded by an application the
/// system installs and launches. This app is that application, and does nothing
/// else.
///
/// It exists because the simulator cannot answer every question. Layered
/// rendering, which the cascade shadow maps rasterize through, is missing
/// there, so the shadow path a device runs is not the path the simulator runs.
@main
struct ImmersiveMapDeviceTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "testtube.2")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("ImmersiveMap device tests")
                    .font(.headline)
                Text("This app only hosts the test bundle. Run the tests from Xcode "
                    + "or xcodebuild; there is nothing to do on this screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
