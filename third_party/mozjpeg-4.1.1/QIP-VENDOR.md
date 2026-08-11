# Vendored MozJPEG 4.1.1

Source: `https://github.com/mozilla/mozjpeg/archive/refs/tags/v4.1.1.tar.gz`

Source archive SHA-256:
`66b1b8d6b55d263f35f27f55acaaa3234df2a401232de99b6d099e2bb0a9d196`

The complete source archive is retained so the QIP encoder can be rebuilt
without a system JPEG library. The Makefile configures a static, 8-bit,
single-threaded wasm32 library with SIMD, arithmetic coding, command-line
tools, TurboJPEG, Java, and optional image-format dependencies disabled.
`jconfig.h` and related target configuration are generated in the temporary
Emscripten build directory rather than copied from the development host.

Two source blocks are guarded by `QIP_FREESTANDING`: the default stderr error
printer and progressive-scan trace printer. QIP supplies a trapping error
manager and does not expose diagnostic stdio, so retaining those unreachable
printers would add WASI file-descriptor imports through libc.

QIP links only `jpeg-static` and uses the libjpeg memory-destination API
through a fixed output buffer and a fixed reclaiming allocator. No filesystem
or backing store is available.

See `LICENSE.md` for the upstream BSD-style and IJG license terms.
