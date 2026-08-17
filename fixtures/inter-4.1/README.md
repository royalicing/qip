# Inter 4.1 Font Fixtures

These files come from the official Inter 4.1 release archive:

- Source: `https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip`
- Archive SHA-256: `9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e`
- `InterDisplay-Regular.ttf` SHA-256: `99614bda7ff423aaf470990692dd93613a5971ab4446e4a6d5a83b3d74865074`
- `InterDisplay-Bold.ttf` SHA-256: `b74c8e0dd744b3347faca4c96bc7b2e32f7d6f62300a79b1d1a99331e44a5bc4`

The two TrueType files are from the archive's `extras/ttf` directory. Inter is
licensed under the SIL Open Font License 1.1. See `LICENSE.txt` in this
directory.

The OG renderer uses the Display faces because its title text is large. The
font files are generation inputs; QIP components embed generated outlines and
metrics instead of reading a font at runtime.
