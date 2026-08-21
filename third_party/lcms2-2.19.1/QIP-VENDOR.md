# Vendored Little CMS 2.19.1

Source archive: `https://sourceforge.net/projects/lcms/files/lcms/2.19.1/lcms2-2.19.1.tar.gz`

Source archive SHA-256:
`bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8`

The `LICENSE` file contains Little CMS's MIT license. The source tree is kept
complete so upgrades can be reviewed against the upstream release. The QIP
build compiles the Little CMS core sources as one LTO-linked wasm32 module. It
does not build the command-line tools, testbed, plugins, JPEG/TIFF frontends,
or a filesystem backend.

The `bmp-b8g8r8a8-icc-to-srgb` component uses only memory-profile loading,
sRGB-profile creation, and 8-bit BGRA transforms. It supplies a fixed arena
allocator and stubs unused file APIs so the final module has no WASI or host
imports. The build targets one thread and enables Wasm SIMD and bulk-memory
instructions.

The upstream release page is
`https://github.com/mm2/Little-CMS/releases/tag/lcms2.19.1`.
