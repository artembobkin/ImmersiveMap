# Text

`Text` owns text atlas parsing, glyph metrics, and text layout: it turns strings
into the glyph geometry that renderer text code draws.

This folder should focus on text data and geometry preparation, not label policy
or provider-specific name selection. Rendering ownership belongs in
`Render/Text`.

## Responsibilities

- Decode text atlas and glyph metric data.
- Measure, wrap, and prepare label text geometry inputs.
- Define text and label vertex data shared with renderer consumers.
- Own `TextLayoutResolver`: renderer-independent measurement and layout that can
  run while tiles are prepared off the main thread.
- Keep text layout behavior independent of vector tile provider schemas.

## May Contain

- Text atlas models and resource readers.
- Glyph, bounds, metrics, and text sizing types.
- Text layout, wrapping, and alignment helpers.
- CPU-side vertex and uniform structs for text rendering.

## Must Not Contain

- Metal code of any kind: the glyph atlas textures and the text pipelines live in
  `Render/Text` (`TextRenderer`, `TextPipelines`), the shaders in
  `Render/Text/Shaders`.
- Provider-specific language fallback or label text field selection.
- Runtime label cache ownership, collision state, or fade animation policy.
- Tile network loading, disk caching, or MVT parsing.
- UI controls, host-app code, tokens, or local secrets.

## Intended Flow

```text
Text resources and label strings
  -> glyph metrics and layout (TextLayoutResolver)
  -> prepared text vertices
  -> renderer text pipelines (Render/Text)
  -> drawable glyphs
```
