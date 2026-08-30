# Vendored ThorVG 1.1.1

Source: `https://github.com/thorvg/thorvg/archive/refs/tags/v1.1.1.tar.gz`

Source archive SHA-256:
`59c12500b7c2fc426e89667b3e4f3fdc2ff05a75cc12001a22c5f58fb1cdf592`

This directory keeps the complete ThorVG 1.1.1 source archive so the QIP SVG
rasterizer can be rebuilt without a system ThorVG installation. The Makefile
compiles only the common code, renderer core, CPU engine, SVG loader, and raw
bitmap loader. GPU engines, threads, file access, animation, external image
decoders, and TTF/OTF font loaders are disabled.

`qip/config.h` is the generated configuration for the little-endian,
single-threaded wasm32 build. It enables only the CPU engine and SVG loader.
The `QIP_SINGLE_THREAD` patch changes the CPU memory-pool pointer from
thread-local to module-global storage and makes its strict lock a no-op. A QIP
component invocation has one thread, so the component does not need WebAssembly
TLS or atomics. It also uses plain storage for the bitmap color-space setting
and suppresses process-exit destructors for module-lifetime loader lists. Each
ThorVG termination still empties those lists explicitly.

See `LICENSE` for the upstream MIT terms.
