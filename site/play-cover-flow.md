# Cover Flow Hifi

The high-fidelity Cover Flow renderer: projective covers, bilinear album sampling, antialiased edges, directional lighting, and spring easing.

Compare against the browser-native [WebGL2 renderer](/play-cover-flow-webgl2) at the same displayed size.

Controls:

- Drag left/right: move through albums with inertia
- Tap an album: select it
- Keyboard: `Left/Right` or `A/D`
- Feature toggles: `L` lighting, `S` spring easing

<qip-play canvas-width="720px" canvas-height="auto">
  <source src="/components/interactive/cover-flow.wasm" type="application/wasm" />
</qip-play>
