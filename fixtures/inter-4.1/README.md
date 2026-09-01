# Inter 4.1 Font Fixtures

These files come from the official Inter 4.1 release archive:

- Source: `https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip`
- Archive SHA-256: `9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e`
- `InterVariable.ttf` SHA-256: `4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf`
- `InterDisplay-Regular.ttf` SHA-256: `99614bda7ff423aaf470990692dd93613a5971ab4446e4a6d5a83b3d74865074`
- `InterDisplay-Bold.ttf` SHA-256: `b74c8e0dd744b3347faca4c96bc7b2e32f7d6f62300a79b1d1a99331e44a5bc4`
- `InterDisplay-Italic.ttf` SHA-256: `20cf47556669f80d12966d2f5eac5054b7486ce5d076feb744dbe24842e2593b`
- `InterDisplay-BoldItalic.ttf` SHA-256: `71e7d3709238b1c21b107ba6433d3a87c6377041a507afd9cf7de3c36ab585f2`

`InterVariable.ttf` is from the archive root. The four Display TrueType files
are from the archive's `extras/ttf` directory. Inter is licensed under the SIL
Open Font License 1.1. See `LICENSE.txt` in this directory.

The OG renderer uses the Display faces because its title text is large. The
font files are generation inputs; QIP components embed generated outlines and
metrics instead of reading a font at runtime.
