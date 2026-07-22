# BMP RGB metrics

`bmp-rgb-metrics.wasm` compares two same-sized, uncompressed BGRA32 BMP files
and emits a JSON report containing RGB MSE, PSNR, and SSIM.

Its single input is the two complete BMP files concatenated in reference-first
order. The first BMP's file-size header locates the second image:

```sh
cat reference.bmp candidate.bmp |
  ./qip run components/image/bmp/bmp-rgb-metrics.wasm
```

The input content type is `application/vnd.qip.bmp-pair`; output is JSON. Each
BMP may be top-down or bottom-up. Width and height must match.

RGB PSNR uses the global mean squared error over all red, green, and blue
samples:

```text
MSE  = sum((reference - candidate)^2) / (width * height * 3)
PSNR = 10 * log10(255^2 / MSE)
```

An exact match reports `"identical": true` and `"psnr_rgb_db": null`, because
its mathematical PSNR is positive infinity.

SSIM matches FFmpeg's 8-bit approximation: uniformly weighted 8x8 windows
overlapping every four pixels, calculated separately for R, G, and B. The
reported `ssim_rgb` is the equal mean of those three channel scores. This is
not the Gaussian-window formulation from the original SSIM paper, nor a
perceptual color-space metric.

The component keeps no image copies or scratch image planes. Its 128 MiB input
capacity is enough for two concatenated BGRA32 BMPs of about 16 megapixels
each. On a 12 MP pair it took about 132 ms under Node and 3.45 seconds in QIP's
default Go/Wasm runtime on the development machine.
