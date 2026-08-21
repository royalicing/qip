# Shadow Rendering Comparison

The sliders are retained component state. Pointer and keyboard events update
them inside a transaction, and `render` publishes the committed view as KTX2.
The component does not expose the slider values as uniforms.

<qip-play canvas-width="1120px" canvas-height="auto">
  <source src="/components/interactive/shadow-rendering.wasm" type="application/wasm" />
</qip-play>
