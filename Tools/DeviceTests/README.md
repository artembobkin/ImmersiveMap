# Device Tests

Runs the package's XCTest suite on a physical iPhone.

`swift test` and the simulator answer most questions, but not every one. The
cascade shadow maps rasterize through layered rendering, which the iOS
simulator does not have: `ShadowCascadeAtlas.supportsLayeredRendering(device:)`
returns false there and the shadow path is skipped rather than exercised. A
case that renders a shadow and measures the result therefore proves nothing in
the simulator, and the hardware every iOS 18 device actually has (Apple5 and
later) is never the hardware under test.

## Why a project at all

SwiftPM test targets are tool-hosted, and `xcodebuild` refuses them on a device:

```text
Cannot test target "ImmersiveMapTests" on "iPhone": Tool-hosted testing is
unavailable on device destinations. Select a host application for the test
target, or use a simulator destination instead.
```

A test bundle on iOS has to be loaded by an application the system installs and
launches. So this project is two targets: `ImmersiveMapDeviceTestHost`, an app
whose whole job is to be that host, and `ImmersiveMapDeviceTests`, the bundle
injected into it.

The test bundle takes its sources straight from `Tests/ImmersiveMapTests`
through a synchronized folder reference, not a copied list of files, and the
test-side MVT encoder and fixture tiles from `Mvt/TestSupport` through a second
one, since the bundle links only the `ImmersiveMap` product and cannot depend
on a package target that is not a product. Those sources, and the `Mvt` module
they and the tests import, are `package` access, so the bundle carries the
package's identity in its `SWIFT_PACKAGE_NAME` build setting (`immersivemap`,
the `-package-name` SwiftPM passes the compiler); without it neither the
encoder nor a test naming `MvtValue` compiles here. The engine test files that
`import MvtTestSupport` guard the line with `#if canImport(MvtTestSupport)`,
because in this bundle those sources are its own and there is no such module.
There is
one suite, and a second list of test files that had to be updated by hand would
be wrong within a week, silently: a device run would pass while quietly not
running the case someone just wrote.

## Running

```sh
xcrun xctrace list devices                      # find the device id

xcodebuild test -project Tools/DeviceTests/ImmersiveMapDeviceTests.xcodeproj \
  -scheme ImmersiveMapDeviceTests -destination 'id=<device-id>'

# one class, once the bundle is already built
xcodebuild test-without-building \
  -project Tools/DeviceTests/ImmersiveMapDeviceTests.xcodeproj \
  -scheme ImmersiveMapDeviceTests -destination 'id=<device-id>' \
  -only-testing:ImmersiveMapDeviceTests/ShadowOffscreenRenderTests
```

The device must be paired, unlocked and trusted. Signing is automatic under the
same development team as the example apps.

Not part of CI, and not a replacement for it. The three checks a pull request
must pass still run on macOS and in the simulator; this is what you reach for
when the question is specifically about hardware behaviour.
