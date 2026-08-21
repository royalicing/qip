# SVG to B8G8R8A8 sRGB BMP

`svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm` rasterizes the repository's
supported SVG subset into a 32-bit BMP. The BMP pixel array uses B8G8R8A8
channel bytes and bottom-up rows. QIP treats the colour channels as sRGB.

The `width` and `height` uniforms override the SVG dimensions.
`background_color_rgba` accepts `0xRRGGBBAA` and defaults to transparent
black.

```sh
./qip run \
  components/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm \
  '?width=1024&height=1024' \
  -i input.svg -o output.bmp
```

SVG input is limited to 1 MiB. Output images are limited to 25,000,000 pixels
and 8192 pixels on either axis.
