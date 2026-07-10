# Avatars

`Avatars` owns the engine-side model and CPU presentation logic for user avatar
markers on the map.

This folder is the boundary where public avatar marker data becomes stable
selection, clustering, and presentation state before renderer-facing avatar draw
code consumes it.

## Responsibilities

- Define public avatar marker data such as coordinates, badges, and cluster
  policy.
- Provide renderer-facing avatar source snapshots.
- Resolve avatar presentation state across frames.
- Project avatars into selection candidates for hit testing.
- Group dense avatar markers into cluster renderables.

## May Contain

- Avatar marker value types and avatar-specific public models.
- Avatar selection projection and hit-test preparation.
- Avatar clustering and layout algorithms.
- Avatar presentation state stores and deterministic animation math.
- Protocols that expose prepared avatar state to the renderer.

## Must Not Contain

- Metal pipelines, shaders, GPU buffers, render passes, or frame graph code.
- Tile loading, vector tile parsing, map styling, or label placement logic.
- UIKit/AppKit/SwiftUI views, gesture recognizers, or host-app controllers.
- Network clients, authorization logic, bearer tokens, or local secrets.
- Non-avatar selection state or general camera/navigation behavior.

## Intended Flow

```text
Public avatar markers
  -> avatar presentation and clustering
  -> avatar selection projection
  -> avatar render source snapshot
  -> Render/Avatars draw code
```
