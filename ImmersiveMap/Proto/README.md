# Proto

`Proto` contains source protobuf schemas used by the package.

Schemas in this folder are source-of-truth inputs for generated code. The
generated Swift output belongs in `Generated`, not here.

## Responsibilities

- Store protobuf schema files used by the vector tile pipeline.
- Keep schema source public-safe and reviewable.
- Provide the source input for generated Swift protobuf files.

## May Contain

- Hand-written `.proto` schema files with the repository source header.
- Public-safe schema comments that explain field meaning.
- Schema files copied into the package resources when needed.

## Must Not Contain

- Generated Swift protobuf output.
- Tile parser implementation, renderer code, or UI runtime code.
- Provider credentials, private endpoints, bearer tokens, or provider access tokens.
- Local generated artifacts, temporary generator output, or build products.
- Schemas unrelated to the ImmersiveMap package.

## Intended Flow

```text
Proto schema
  -> protobuf generator
  -> Generated Swift source
  -> tile parsing pipeline
```
