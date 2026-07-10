# Render

`Render` owns Metal-facing frame construction, render graph execution, GPU
resources, and renderer subsystems.

This folder is the runtime drawing boundary. Data should arrive here already
parsed, styled, normalized, and prepared for rendering.

## Responsibilities

- Build and execute the render graph for each frame.
- Own Metal pipelines, render passes, GPU resources, shaders, and frame
  attachments.
- Resolve renderer camera state and frame visibility.
- Draw tiles, labels, avatars, globe surfaces, starfield, debug overlays, and
  related GPU output.
- Keep renderer-specific resource lifetime and frame timing isolated.

## May Contain

- Metal renderer classes and frame engine code.
- Shader files, compute kernels, and renderer resources.
- Render graph, pass graph, and frame attachment infrastructure.
- GPU-facing structs, uniforms, buffers, texture stores, and pipeline builders.
- Debug rendering utilities that observe renderer state.

## Must Not Contain

- Network tile fetching, URL construction, authorization, or disk cache policy,
  except the self-contained night-lights texture-source loader under `EarthScene/`
  (`NightLightsTileSet` / `NightLightsTileCache`), which fetches and disk-caches its
  own raster tiles.
- Raw vector tile provider adaptation and label decision policy.
- UIKit/AppKit/SwiftUI views, gesture recognizers, public UI controllers, or
  host-app lifecycle code.
- Public configuration API unrelated to rendering.
- Secrets, tokens, private endpoints, or local machine paths.

## Intended Flow

```text
Prepared runtime state
  -> render frame engine
  -> render graph and pass encoders
  -> Metal pipelines and GPU resources
  -> drawable output
```
