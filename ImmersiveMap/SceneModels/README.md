# SceneModels

`SceneModels` owns the engine-side model and CPU presentation logic for 3D
models anchored at geographic coordinates.

This folder is the boundary where public scene model descriptors become stable
presentation state (animated position, orientation, scale, altitude) before
renderer-facing scene model draw code consumes it.

## Responsibilities

- Define the public scene model descriptor: asset source, coordinate, altitude,
  orientation, and real-world-meter sizing.
- Provide renderer-facing scene model source snapshots.
- Resolve scene model presentation state across frames with deterministic
  animation math (great-circle position, quaternion orientation, scalar easing).
- Fly a model along an `ImmersiveMapGeoPath`: position, altitude, heading and
  pitch come from the shared path sampler in `Geo`, so the model rides exactly
  on the route drawn for the same path.
- Resolve a tap against the models a frame drew: `Selection` holds the per-frame
  hit volumes and the ray math that inverts the frame's own projection, so a
  hit means the tap landed on the model where it appears.

## May Contain

- Scene model value types and scene-model-specific public models.
- Scene model presentation state stores and deterministic animation math.
- Per-frame hit-test snapshots and the pure geometry that queries them.
- Protocols that expose prepared scene model state to the renderer.

## Must Not Contain

- Metal pipelines, shaders, GPU buffers, render passes, or frame graph code.
- Model I/O / MetalKit asset loading (lives in `Render/SceneModels`, which owns
  the Metal device).
- Tile loading, vector tile parsing, map styling, or label placement logic.
- UIKit/AppKit/SwiftUI views, gesture recognizers, or host-app controllers.
- Networking of any kind: sources are local file URLs only.

## Intended Flow

```text
Public scene models
  -> scene model snapshot
  -> scene model presentation state
  -> Render/SceneModels anchor math and draw code
  -> selection snapshot of the drawn models
  -> UI tap hit-test
```
