# SVG to canonical RGBA8 sRGB KTX2

`svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm` rasterizes the repository's
supported SVG subset directly into QIP's canonical
`VK_FORMAT_R8G8B8A8_SRGB` KTX2 profile. Rows and RGBA channels are written in
their final top-down (`KTXorientation=rd`) order.

The component has the same SVG support and `width`, `height`, and
`background_color` uniforms as `svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm`. The output retains
straight alpha when no opaque background is requested.

```sh
./qip run \
  components/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm \
  '?width=1024&height=1024' \
  -i input.svg -o output.ktx2
```

SVG input is limited to 1 MiB. Output images are limited to 25,000,000 pixels
and 8192 pixels on either axis.
