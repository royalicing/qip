# God Rays

A software-rendered port of the [paper-design god-rays shader](https://shaders.paper.design/god-rays), evaluating the GLSL fragment shader per pixel in WebAssembly. Both use the library's "Default" preset.

Straight port (line-for-line GLSL translation, libm `pow`/`atan2`):

<qip-play canvas-width="640px" canvas-height="360px">
  <source src="/components/interactive/god-rays.wasm" type="application/wasm" />
</qip-play>

Optimized port (polynomial `pow`/`atan2`, hoisted angle, saturated-mix branch skip — output within 1/255 per channel of the straight port):

<qip-play canvas-width="640px" canvas-height="360px">
  <source src="/components/interactive/god-rays-optimized.wasm" type="application/wasm" />
</qip-play>
