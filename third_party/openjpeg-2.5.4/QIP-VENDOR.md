# Vendored OpenJPEG 2.5.4

Source: `https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.4.tar.gz`

Source archive SHA-256:
`a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a`

This directory keeps OpenJPEG's complete `src/lib/openjp2` directory so the
QIP decoder can be rebuilt without a system OpenJPEG installation. The
`opj_config.h` and `opj_config_private.h` files are the generated configuration
for the little-endian, single-threaded wasm32 build.

The Makefile compiles only the library sources required for decoding. It does
not build OpenJPEG's applications or their optional PNG, TIFF, zlib, and LCMS
dependencies.

See `LICENSE` for the upstream BSD 2-Clause terms.
