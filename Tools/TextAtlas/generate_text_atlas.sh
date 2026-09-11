#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  generate_text_atlas.sh --font /path/to/font.ttf|otf [options]

Required:
  --font PATH              Primary font for atlas.json and atlas.bgra.

Options:
  --thin-font PATH         Font for atlas_thin.json and atlas_thin.bgra.
                           Defaults to --font for pipeline smoke tests.
  --charset PATH           Charset file. Defaults to
                           Tools/TextAtlas/charsets/labels-basic.txt.
  --output-dir PATH        Output resource directory. Defaults to
                           ImmersiveMap/Text/Resources.
  --msdf-atlas-gen PATH    msdf-atlas-gen executable. Defaults to PATH lookup.
  --pxrange PIXELS         MSDF distance range. Defaults to 24.
  --width PIXELS           Fixed atlas width. Defaults to 2048.
  --height PIXELS          Fixed atlas height. Defaults to 2048.
  -h, --help               Show this help.

Generated outputs:
  atlas.json, atlas.bgra, atlas_thin.json, atlas_thin.bgra

The .bgra files are the atlas pixels as they go to the GPU: BGRA8 (the
byte order of Metal's bgra8Unorm), row major, top row first,
width * height * 4 bytes, no header (the JSON carries the dimensions). msdf-atlas-gen writes a PNG, which png_to_rgba.swift
(next to this script, compiled on the fly) unpacks, so the engine uploads
the texture without an image decode.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$initial_cwd" "$1" ;;
  esac
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || fail "$option requires a value"
}

validate_positive_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer: $value"
}

find_generator() {
  local candidate="$1"

  if [[ "$candidate" == */* ]]; then
    candidate="$(resolve_path "$candidate")"
    [[ -x "$candidate" ]] || fail "msdf-atlas-gen is not executable: $candidate"
    printf '%s\n' "$candidate"
    return
  fi

  command -v "$candidate" >/dev/null 2>&1 || fail "msdf-atlas-gen not found on PATH; pass --msdf-atlas-gen"
  command -v "$candidate"
}

strip_charset_comments() {
  local source="$1"
  local destination="$2"

  sed -E 's/[[:space:]]*#.*$//' "$source" | awk 'NF { print }' >"$destination"
  [[ -s "$destination" ]] || fail "charset is empty after stripping comments: $source"
}

generate_atlas() {
  local font_path="$1"
  local json_name="$2"
  local image_name="$3"
  local work_dir="$4"
  local json_output="$work_dir/$json_name"
  local image_output="$work_dir/$image_name"

  "$generator_path" \
    -font "$font_path" \
    -charset "$clean_charset" \
    -type mtsdf \
    -format png \
    -size 64 \
    -pxrange "$atlas_pxrange" \
    -dimensions "$atlas_width" "$atlas_height" \
    -yorigin bottom \
    -imageout "$image_output" \
    -json "$json_output"

  [[ -s "$json_output" ]] || fail "missing generated JSON: $json_output"
  [[ -s "$image_output" ]] || fail "missing generated PNG: $image_output"
}

# Unpacks a generated PNG into the raw RGBA8 file the engine loads.
unpack_atlas() {
  local work_dir="$1"
  local image_name="$2"
  local raw_name="$3"

  "$converter_path" "$work_dir/$image_name" "$work_dir/$raw_name"
  [[ -s "$work_dir/$raw_name" ]] || fail "missing unpacked atlas: $work_dir/$raw_name"
}

build_converter() {
  local work_dir="$1"
  local source="$script_dir/png_to_rgba.swift"

  [[ -f "$source" ]] || fail "missing converter source: $source"
  swiftc -O -o "$work_dir/png_to_rgba" "$source" || fail "could not compile png_to_rgba.swift"
  printf '%s\n' "$work_dir/png_to_rgba"
}

install_output() {
  local work_dir="$1"
  local name="$2"

  cp "$work_dir/$name" "$output_dir/$name"
}

initial_cwd="$(pwd -P)"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"

font_path=""
thin_font_path=""
charset_path="$repo_root/Tools/TextAtlas/charsets/labels-basic.txt"
output_dir="$repo_root/ImmersiveMap/Text/Resources"
generator="msdf-atlas-gen"
atlas_pxrange="24"
atlas_width="2048"
atlas_height="2048"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --font)
      require_value "$1" "${2:-}"
      font_path="$(resolve_path "$2")"
      shift 2
      ;;
    --thin-font)
      require_value "$1" "${2:-}"
      thin_font_path="$(resolve_path "$2")"
      shift 2
      ;;
    --charset)
      require_value "$1" "${2:-}"
      charset_path="$(resolve_path "$2")"
      shift 2
      ;;
    --output-dir)
      require_value "$1" "${2:-}"
      output_dir="$(resolve_path "$2")"
      shift 2
      ;;
    --msdf-atlas-gen)
      require_value "$1" "${2:-}"
      generator="$2"
      shift 2
      ;;
    --pxrange)
      require_value "$1" "${2:-}"
      atlas_pxrange="$2"
      shift 2
      ;;
    --width)
      require_value "$1" "${2:-}"
      atlas_width="$2"
      shift 2
      ;;
    --height)
      require_value "$1" "${2:-}"
      atlas_height="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ -n "$font_path" ]] || fail "--font is required"
[[ -f "$font_path" ]] || fail "font file does not exist: $font_path"
[[ "$font_path" =~ \.(ttf|otf|TTF|OTF)$ ]] || fail "font must be a .ttf or .otf file: $font_path"

if [[ -z "$thin_font_path" ]]; then
  thin_font_path="$font_path"
fi

[[ -f "$thin_font_path" ]] || fail "thin font file does not exist: $thin_font_path"
[[ "$thin_font_path" =~ \.(ttf|otf|TTF|OTF)$ ]] || fail "thin font must be a .ttf or .otf file: $thin_font_path"
[[ -f "$charset_path" ]] || fail "charset file does not exist: $charset_path"
validate_positive_integer "--width" "$atlas_width"
validate_positive_integer "--height" "$atlas_height"
validate_positive_integer "--pxrange" "$atlas_pxrange"

generator_path="$(find_generator "$generator")"
mkdir -p "$output_dir"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
clean_charset="$tmp_dir/charset.txt"
strip_charset_comments "$charset_path" "$clean_charset"

converter_path="$(build_converter "$tmp_dir")"

generate_atlas "$font_path" "atlas.json" "atlas.png" "$tmp_dir"
generate_atlas "$thin_font_path" "atlas_thin.json" "atlas_thin.png" "$tmp_dir"
unpack_atlas "$tmp_dir" "atlas.png" "atlas.bgra"
unpack_atlas "$tmp_dir" "atlas_thin.png" "atlas_thin.bgra"

install_output "$tmp_dir" "atlas.json"
install_output "$tmp_dir" "atlas.bgra"
install_output "$tmp_dir" "atlas_thin.json"
install_output "$tmp_dir" "atlas_thin.bgra"

printf 'Generated text atlas resources in %s\n' "$output_dir"
