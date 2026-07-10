# Labels

`Labels` owns runtime label state after provider-specific vector tile decisions
have already been normalized.

This folder is responsible for label caches, collision inputs, draw batches, and
runtime metadata. It should not know the raw provider schema.

## Responsibilities

- Store base and road label runtime state.
- Prepare label collision candidates and draw batches.
- Track label placement metadata and visible tile indices.
- Resolve POI sprite identifiers for already-normalized label data.
- Maintain cache state needed for label continuity across frames.

## May Contain

- Label cache and rebuild-state types.
- Collision input models and runtime label metadata.
- Road label path, glyph, anchor, and range models.
- POI sprite resolution helpers.
- Draw batch structs consumed by renderer label subsystems.

## Must Not Contain

- Provider-specific vector tile schema rules, language fallback policy, or label
  identity decisions that belong in `VectorTileAdaptation`.
- Metal pipelines, shaders, GPU buffer allocation, or render pass encoding.
- Tile downloading, disk caching, or raw MVT parsing.
- UIKit/AppKit/SwiftUI views, gesture handlers, or host-app controllers.
- Network authorization, tokens, or local secret configuration.

## Intended Flow

```text
Normalized label decisions
  -> label source entries
  -> runtime label caches
  -> collision and draw batches
  -> Render/Labels draw code
```
