#!/bin/sh
set -eu

if [ ! -x ./qip ]; then
  echo "qip binary not found; run 'make qip'" >&2
  exit 1
fi

if [ ! -f examples/svg-rasterize.wasm ]; then
  echo "examples/svg-rasterize.wasm not found; build it first" >&2
  exit 1
fi

if ! command -v shasum >/dev/null 2>&1; then
  echo "shasum not available" >&2
  exit 1
fi

SVG=$(cat <<'SVG'
<svg width="12" height="8">
  <rect x="0" y="0" width="4" height="8" fill="#ff0000"/>
  <circle cx="9" cy="2" r="2" fill="#00ff00"/>
  <g transform="translate(1,0)" fill="#0000ff">
    <polygon points="6,5 11,5 11,7"/>
  </g>
</svg>
SVG
)

expected="2aa64eea4ded8529fe0d5203252cda59ffe4266a9be4a4423793c6cee7bfa6d7"
actual=$(printf "%s" "$SVG" | ./qip run examples/svg-rasterize.wasm 2>/dev/null | shasum -a 256 | awk '{print $1}')

if [ "$actual" != "$expected" ]; then
  echo "svg-rasterize hash mismatch" >&2
  echo "expected: $expected" >&2
  echo "actual:   $actual" >&2
  exit 1
fi

printf "%s" "$SVG" | ./qip run examples/svg-rasterize.wasm 2>/dev/null > tmp/svg.bmp

echo "svg-rasterize ok"
