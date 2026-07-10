# UI

`UI` owns the public SwiftUI surface, the platform host views (UIKit on iOS,
AppKit on macOS), and runtime controllers that connect user interaction, camera
commands, selection, settings, tiles, and rendering.

This folder is the integration layer for app-facing usage. It should coordinate
engine subsystems without taking over their internal responsibilities. The
public SwiftUI API (`ImmersiveMapView` and its modifiers) is identical on both
platforms; only the host view, gestures, and overlay controls are
platform-specific.

## Responsibilities

- Expose the public SwiftUI map view and the platform host views
  (`ImmersiveMapUIView` on iOS, `ImmersiveMapNSView` on macOS).
- Own runtime graph construction for the interactive map surface.
- Handle gestures, controls, camera commands, selection events, and viewport
  updates.
- Connect render driver pacing with engine runtime controllers.
- Provide test-support hooks for UI-level integration behavior.

## May Contain

- Public `UIView`/`NSView` host views and their `UIViewRepresentable`/
  `NSViewRepresentable` bridges.
- UIKit and AppKit controls, gesture controllers, and interaction runtimes in
  per-platform files (`#if canImport(UIKit)` / `#if os(macOS)`).
- Platform-neutral shared logic: `ImmersiveMapHostRuntime`, the runtime graph,
  camera/selection/avatar/viewport/controls/render runtime controllers, and the
  `ImmersiveMapHostView` typealias that shared files reference.
- Render loop pacing, the platform `DisplayLinkFactory`, and render driver
  delegates.
- Public UI-facing controller types.

## Must Not Contain

- Metal pipeline creation, shader files, render graph internals, or GPU resource
  lifetime that belongs in `Render`.
- Raw tile parsing, feature styling, disk caching internals, or MVT decode code.
- Provider-specific label adaptation or language fallback policy.
- `targetEnvironment(macCatalyst)` checks - the package targets iOS (UIKit) and
  native macOS (AppKit) only.
- Host-app-only app delegates, scene setup, launch environment parsing, or demo
  mode code.
- Bearer tokens, Mapbox tokens, private endpoints, or local secret files.

## Intended Flow

```text
App-facing map view (SwiftUI -> platform host view)
  -> shared host runtime
  -> UI runtime graph
  -> interaction, camera, tile, avatar, and selection controllers
  -> render driver
  -> Render frame engine
```
