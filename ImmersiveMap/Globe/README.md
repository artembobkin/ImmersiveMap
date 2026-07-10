# Globe

`Globe` owns CPU-side globe presentation models that are shared by tile
visibility, presentation, and renderer setup.

This folder is for globe-specific decisions before work becomes Metal frame
encoding or tile loading.

## Responsibilities

- Describe globe uniforms and visibility inputs.
- Resolve globe tile visibility bounds.
- Cache and reuse globe visibility calculations where appropriate.
- Keep globe math separate from flat-map presentation code.

## May Contain

- Globe visibility input and output models.
- CPU-side globe uniform structs shared with render setup.
- Globe-specific culling and tile-bound helpers.
- Deterministic math for globe coverage and visibility decisions.

## Must Not Contain

- Metal pipeline creation, render passes, GPU texture trees, or shader files.
- Tile network loading, disk caching, or vector tile parsing.
- UIKit/AppKit/SwiftUI controls, gesture recognizers, or host-app code.
- Provider-specific label or feature schema adaptation.
- Flat-map-only visibility behavior that belongs in `Tile` or `Presentation`.

## Intended Flow

```text
Camera and presentation state
  -> globe visibility inputs
  -> globe tile visibility bounds
  -> tile and render consumers
```
