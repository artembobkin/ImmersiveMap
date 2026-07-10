# Text

`Text` owns text atlas parsing, glyph metrics, text layout inputs, and the
`TextRenderer` that draws prepared label text with Metal.

This folder should focus on text data, geometry preparation, and text drawing,
not label policy or provider-specific name selection.

## Responsibilities

- Decode text atlas and glyph metric data.
- Measure, wrap, and prepare label text geometry inputs.
- Define text and label vertex data shared with renderer consumers.
- Own `TextRenderer`: build the text render pipeline and its glyph-atlas GPU textures.
- Keep text layout behavior independent of vector tile provider schemas.

## May Contain

- Text atlas models and resource readers.
- Glyph, bounds, metrics, and text sizing types.
- Text layout, wrapping, and alignment helpers.
- CPU-side vertex and uniform structs for text rendering.
- `TextRenderer` and the text render pipeline it builds (glyph-atlas textures, command queue).

## Must Not Contain

- Provider-specific language fallback or label text field selection.
- Runtime label cache ownership, collision state, or fade animation policy.
- Metal shader source files (text shaders live in `Render/Text/`) or render-graph pass orchestration.
- Tile network loading, disk caching, or MVT parsing.
- UI controls, host-app code, tokens, or local secrets.

## Intended Flow

```text
Text resources and label strings
  -> glyph metrics and layout
  -> prepared text vertices
  -> TextRenderer Metal draw
```
