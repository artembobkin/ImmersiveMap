# Presentation

`Presentation` resolves the high-level map presentation state shared by globe,
flat, camera, tile, and render layers.

This folder describes how the map should be presented. It does not own the UI
surface that receives gestures or the renderer that draws frames.

## Responsibilities

- Resolve semantic world state from camera and view-mode input.
- Describe normalized render state for globe and flat presentation.
- Provide presentation state controllers used by runtime layers.
- Keep globe/flat switching logic in one provider-neutral boundary.

## May Contain

- Presentation state value types.
- Resolvers for globe, flat, and screen-space presentation modes.
- Controllers that track high-level presentation transitions.
- Pure helpers that convert camera/view-mode input into presentation output.

## Must Not Contain

- UIKit/AppKit/SwiftUI views, controls, and gesture recognizers.
- Metal render graph, render passes, shaders, or GPU resource ownership.
- Tile network loading, vector tile parsing, or disk cache policy.
- Provider-specific label adaptation or feature styling rules.
- Host-app launch configuration, auth tokens, or local secrets.

## Intended Flow

```text
Camera and view mode
  -> presentation resolver
  -> resolved presentation state
  -> tile visibility and render consumers
```
