#include "src/enc/vp8i_enc.h"

// The opaque component composites declared BMP alpha before calling libwebp.
// These definitions replace alpha_enc.c, making that contract visible to LTO
// so the VP8L alpha compressor can be removed from the final module.
void VP8EncInitAlpha(VP8Encoder* const enc) {
  enc->has_alpha = 0;
  enc->alpha_data = NULL;
  enc->alpha_data_size = 0;
}

int VP8EncStartAlpha(VP8Encoder* const enc) {
  (void)enc;
  return 1;
}

int VP8EncFinishAlpha(VP8Encoder* const enc) {
  return WebPReportProgress(enc->pic, enc->percent + 20, &enc->percent);
}

int VP8EncDeleteAlpha(VP8Encoder* const enc) {
  enc->alpha_data = NULL;
  enc->alpha_data_size = 0;
  enc->has_alpha = 0;
  return 1;
}
