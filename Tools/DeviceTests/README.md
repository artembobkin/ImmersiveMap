# Device Tests

Runs the package's XCTest suite on a physical iPhone. Everything on this page
is about this project alone: what it is made of, what it reads, and how it
runs.

## Why a project at all

SwiftPM test targets are tool-hosted, and `xcodebuild` refuses them on a device:

```text
Cannot test target "ImmersiveMapTests" on "iPhone": Tool-hosted testing is
unavailable on device destinations. Select a host application for the test
target, or use a simulator destination instead.
```

On iOS a test bundle has to be loaded by an application the system installs
and launches. So this project is two targets: `ImmersiveMapDeviceTestHost`, an
app whose whole job is to be that host (`Host/`), and `ImmersiveMapDeviceTests`,
the bundle injected into it.

## What the project reads

The project owns no test of its own. It takes its sources from the package
through synchronized folder references, so there is no second list of files
to keep in step:

- `Tests/ImmersiveMapTests`: the whole suite, as it is.
- `Sources/MvtTestSupport`: the test-side MVT encoder and the fixture tiles,
  compiled into the bundle as its own sources. The bundle links only the
  `ImmersiveMap` product and cannot depend on a package target that is not a
  product.

Those sources, and the `Mvt` module they import, are `package` access, so the
bundle carries the package's identity in its `SWIFT_PACKAGE_NAME` build
setting (`immersivemap`, the `-package-name` SwiftPM passes the compiler).
Without it neither the encoder nor a test naming an `Mvt` type compiles here.
A test file that writes `import MvtTestSupport` guards the line with
`#if canImport(MvtTestSupport)`, because in this bundle there is no such
module: its sources are the bundle's own.

If one of those two folders moves, the references in
`ImmersiveMapDeviceTests.xcodeproj` move with it, and this page too.

## Running

```sh
xcrun xctrace list devices                      # find the device id

xcodebuild test -project Tools/DeviceTests/ImmersiveMapDeviceTests.xcodeproj \
  -scheme ImmersiveMapDeviceTests -destination 'id=<device-id>'

# one class, once the bundle is already built
xcodebuild test-without-building \
  -project Tools/DeviceTests/ImmersiveMapDeviceTests.xcodeproj \
  -scheme ImmersiveMapDeviceTests -destination 'id=<device-id>' \
  -only-testing:ImmersiveMapDeviceTests/<TestClass>
```

The device must be paired, unlocked and trusted. Signing is automatic, under
the development team set in the project.

A test that reads a file off the checkout (a `.metal` source, a fixture by
path) cannot pass on a device, where there is no checkout. Filter such tests
out with `-only-testing:` rather than reading them as failures.

## When to reach for it

The simulator is a software renderer with gaps of its own: a GPU path the
simulator lacks is skipped there, not exercised, and a case that measures what
such a path draws proves nothing in the simulator. A device is the only place
the real GPU's timing, memory and driver behaviour can be measured. This is
what to run when the question is specifically about hardware. It is not part
of CI and not a replacement for it.
