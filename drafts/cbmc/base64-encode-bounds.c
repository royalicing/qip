#include <assert.h>
#include <stdint.h>

#ifndef QIP_INPUT_BYTES_CAP
#define QIP_INPUT_BYTES_CAP 65536u
#endif

#ifndef QIP_OUTPUT_UTF8_CAP
#define QIP_OUTPUT_UTF8_CAP 65536u
#endif
#define QIP_BASE64_MAX_FULL_GROUPS (QIP_INPUT_BYTES_CAP / 3u)
#define QIP_BASE64_MAX_SAFE_INPUT ((QIP_OUTPUT_UTF8_CAP / 4u) * 3u)

uint32_t nondet_uint32_t(void);

uint32_t base64_full_group_iterations(uint32_t input_size) {
  __CPROVER_assume(input_size <= QIP_INPUT_BYTES_CAP);

  uint32_t input_idx = 0;
  uint32_t full_end = input_size - (input_size % 3u);
  uint32_t iterations = 0;

  while (input_idx < full_end)
    __CPROVER_loop_invariant(input_size <= QIP_INPUT_BYTES_CAP)
    __CPROVER_loop_invariant(full_end <= input_size)
    __CPROVER_loop_invariant(full_end <= QIP_INPUT_BYTES_CAP)
    __CPROVER_loop_invariant(full_end % 3u == 0u)
    __CPROVER_loop_invariant(input_size - full_end <= 2u)
    __CPROVER_loop_invariant(input_idx <= full_end)
    __CPROVER_loop_invariant(input_idx % 3u == 0u)
    __CPROVER_loop_invariant(iterations == input_idx / 3u)
    __CPROVER_loop_invariant(iterations <= QIP_BASE64_MAX_FULL_GROUPS)
    __CPROVER_decreases(full_end - input_idx)
  {
    assert(input_idx + 2u < input_size);

    input_idx += 3u;
    iterations += 1u;

    assert(iterations <= QIP_BASE64_MAX_FULL_GROUPS);
  }

  assert(input_idx == full_end);
  assert(input_size - input_idx <= 2u);
  assert(iterations <= QIP_BASE64_MAX_FULL_GROUPS);

  return iterations;
}

uint32_t base64_output_size(uint32_t input_size) {
  __CPROVER_assume(input_size <= QIP_BASE64_MAX_SAFE_INPUT);

  uint32_t full_groups = input_size / 3u;
  uint32_t tail = input_size % 3u;
  uint32_t output_size = full_groups * 4u;

  if (tail != 0u) {
    output_size += 4u;
  }

  assert(output_size <= QIP_OUTPUT_UTF8_CAP);
  return output_size;
}

int main(void) {
  uint32_t input_size = nondet_uint32_t();

  base64_full_group_iterations(input_size);
  base64_output_size(input_size);

  return 0;
}
