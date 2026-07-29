# Markers

`Markers` owns the engine-facing contract for SwiftUI marker overlays: the
per-frame projection input read by the render frame and the projected screen
snapshot published back to the UI layer.

This folder is deliberately tiny. Marker content (SwiftUI views, hosting
views, containers) lives in `UI`; the projection math lives next to the
renderer. `Markers` only defines the value types and protocols that cross
that boundary.

## Responsibilities

- Define the marker projection input (internal ids plus cached coordinate
  bases) the render frame reads each frame.
- Define the projected marker snapshot (screen positions in drawable pixels,
  visibility alpha) published back to the UI layer.
- Expose the `MarkerRenderSource` protocol implemented by the UI marker
  runtime.

## May Contain

- Marker projection input/output value types.
- Protocols that expose prepared marker state to the renderer.

## Must Not Contain

- Metal pipelines, shaders, GPU buffers, render passes, or frame graph code.
- UIKit/AppKit/SwiftUI views, hosting controllers, or gesture recognizers.
- Networking, tile loading, or provider adaptation.
- Avatar, label, or selection logic.

## Intended Flow

```text
UI marker runtime (ImmersiveMapMarkerRuntime)
  -> MarkerRenderSource input (ids + GeoProjectionBasis)
  -> MarkerRenderSubsystem projection inside the frame
  -> MarkerProjectionSnapshot
  -> RenderFrameEventSink -> UI marker runtime applies view positions
```
