# Routes

`Routes` owns the engine-side model and CPU presentation logic for routes drawn
over the globe: great-circle ribbons following an `ImmersiveMapGeoPath`.

This folder is the boundary where public route descriptors become stable
presentation state (tessellated samples, animated progress) before
renderer-facing route draw code consumes it.

## Responsibilities

- Define the public route descriptor: path, color, width, progress.
- Provide renderer-facing route source snapshots.
- Resolve route presentation state across frames: cache the tessellation of a
  path and animate progress deterministically.

## May Contain

- Route value types and route-specific public models.
- Route presentation state stores and deterministic animation math.
- Protocols that expose prepared route state to the renderer.

## Must Not Contain

- Metal pipelines, shaders, GPU buffers, render passes, or frame graph code.
- World-space geometry building (lives in `Render/Routes`, which owns the frame
  constants and the Metal device).
- Great-circle interpolation or path sampling (lives in `Geo`, shared with
  scene model animation).
- Tile loading, vector tile parsing, map styling, or label placement logic.
- UIKit/AppKit/SwiftUI views, gesture recognizers, or host-app controllers.
- Networking of any kind.

## Intended Flow

```text
Public routes
  -> routes snapshot
  -> route presentation state (samples + animated progress)
  -> Render/Routes world geometry build and draw code
```
