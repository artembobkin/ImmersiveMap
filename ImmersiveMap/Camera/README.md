# Camera

`Camera` owns the engine-side camera state and view-mode math that is independent
of UIKit/AppKit gestures, SwiftUI bindings, and Metal frame encoding.

This folder keeps camera constraints and transformations reusable by UI,
presentation, tile visibility, and render code without making those layers own
camera policy.

## Responsibilities

- Define camera state used by the map engine.
- Resolve camera constraints such as bearing, pitch, and zoom limits.
- Provide gesture-independent zoom and view-mode math.
- Describe the active map view mode in provider-neutral terms.

## May Contain

- Camera state value types and internal camera controllers.
- Bearing, pitch, zoom, and pinch math.
- View-mode definitions shared across presentation and rendering.
- Pure helpers that transform camera input into constrained camera output.

## Must Not Contain

- UIKit/AppKit/SwiftUI gesture recognizers, controls, or view lifecycle code.
- Metal resources, render passes, frame state, or shader-facing structs that are
  owned by `Render`.
- Tile fetching, vector tile parsing, cache policy, or provider configuration.
- Host-app launch environment handling or secret configuration.
- Label, avatar, or starfield runtime ownership.

## Intended Flow

```text
Camera input
  -> camera state controller
  -> constraint resolver
  -> presentation and render consumers
```
