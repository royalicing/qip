#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";

const [kind, outputPath, ...headerPaths] = process.argv.slice(2);
if (!["qip", "wasm2c"].includes(kind) || !outputPath || headerPaths.length < 2) {
  console.error(
    "usage: generate-content-recipe-c.mjs qip|wasm2c output.c header.h ...",
  );
  process.exit(2);
}

function quoted(value) {
  return JSON.stringify(value);
}

function qipStep(path, index) {
  const source = readFileSync(path, "utf8");
  const match = source.match(
    /^#define (qip_wasm_[0-9a-f]+)_MEMORY_SIZE /m,
  );
  if (!match) throw new Error(`cannot find QIP generated prefix in ${path}`);
  return { index, path, prefix: match[1] };
}

function wasm2cStep(path, index) {
  const source = readFileSync(path, "utf8");
  const type = source.match(/typedef struct (w2c_[A-Za-z0-9_]+) \{/);
  const inputCap = source.match(
    /\/\* export: 'input_(?:utf8|bytes)_cap' \*\/\s+u32 ([A-Za-z0-9_]+)\(/,
  );
  const outputCap = source.match(
    /\/\* export: 'output_(?:utf8|bytes)_cap' \*\/\s+u32 ([A-Za-z0-9_]+)\(/,
  );
  if (!type || !inputCap || !outputCap) {
    throw new Error(`cannot find Content exports in ${path}`);
  }
  const prefix = type[1];
  return {
    index,
    path,
    prefix,
    module: prefix.replace(/^w2c_/, ""),
    inputCap: inputCap[1],
    outputCap: outputCap[1],
  };
}

const steps = headerPaths.map(kind === "qip" ? qipStep : wasm2cStep);

const commonPrefix = `#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

#define MAX_SAMPLES 1000000u

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static int compare_double(const void *a, const void *b) {
  double av = *(const double *)a;
  double bv = *(const double *)b;
  return (av > bv) - (av < bv);
}

static uint64_t current_rss(void) {
#if defined(__APPLE__)
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(
          mach_task_self(),
          MACH_TASK_BASIC_INFO,
          (task_info_t)&info,
          &count) == KERN_SUCCESS) return info.resident_size;
#endif
  return 0;
}

static void print_summary(double *samples, size_t count) {
  double sum = 0.0;
  size_t i;
  for (i = 0; i < count; ++i) sum += samples[i];
  qsort(samples, count, sizeof(*samples), compare_double);
  printf(
      "\\"warm_recipe\\":{\\"samples\\":%zu,\\"mean_ms\\":%.9f,"
      "\\"p50_ms\\":%.9f,\\"p95_ms\\":%.9f,\\"max_ms\\":%.9f}",
      count,
      sum / (double)count,
      samples[count / 2],
      samples[(count * 95) / 100],
      samples[count - 1]);
}

static int read_input(const char *path, uint8_t **bytes, uint32_t *size) {
  FILE *file = fopen(path, "rb");
  long length;
  if (!file || fseek(file, 0, SEEK_END) ||
      (length = ftell(file)) < 0 || (uint64_t)length > UINT32_MAX ||
      fseek(file, 0, SEEK_SET)) return 0;
  *bytes = malloc((size_t)length + 1u);
  if (!*bytes ||
      fread(*bytes, 1, (size_t)length, file) != (size_t)length) return 0;
  fclose(file);
  *size = (uint32_t)length;
  return 1;
}

static int write_output(const char *path, const uint8_t *bytes, uint32_t size) {
  FILE *file = fopen(path, "wb");
  if (!file || fwrite(bytes, 1, size, file) != size) return 0;
  return fclose(file) == 0;
}
`;

function qipSource() {
  const includes = steps
    .map(({ path }) => `#include ${quoted(path)}`)
    .join("\n");
  const fields = steps
    .map(({ prefix, index }) => `  ${prefix}_instance step_${index + 1};`)
    .join("\n");
  const sizes = steps
    .map(({ prefix }) => `(size_t)${prefix}_MEMORY_SIZE`)
    .join(",\n  ");
  const renders = steps
    .map(({ prefix, index }) => {
      const n = index + 1;
      const copy = index === 0
        ? `  if (input_size > ${prefix}_INPUT_CAPACITY) return 0;
  memcpy(
      r->workspaces[${index}].memory + ${prefix}_INPUT_OFFSET,
      input,
      input_size);
  n = input_size;`
        : `  if (n > ${prefix}_INPUT_CAPACITY) return 0;
#if QIP_RECIPE_SHARED_WORKSPACE
  memmove(
      r->workspaces[${index}].memory + ${prefix}_INPUT_OFFSET,
      r->workspaces[${index - 1}].memory + offset,
      n);
#else
  memcpy(
      r->workspaces[${index}].memory + ${prefix}_INPUT_OFFSET,
      r->workspaces[${index - 1}].memory + offset,
      n);
#endif`;
      return `${copy}
  if (${prefix}_init(
          &r->step_${n}, &r->workspaces[${index}], n) != ${prefix}_OK ||
      ${prefix}_render(
          &r->step_${n}, n, &offset, &n) != ${prefix}_OK) return 0;`;
    })
    .join("\n\n");
  const clears = steps
    .map((_, index) => `  qip_render_workspace_clear(&r->workspaces[${index}]);`)
    .join("\n");
  const frees = steps
    .map((_, index) => `  free(r->workspaces[${index}].memory);`)
    .join("\n");

  return `${commonPrefix}
#ifndef QIP_RECIPE_SHARED_WORKSPACE
#define QIP_RECIPE_SHARED_WORKSPACE 1
#endif

#define QIP_WASM_IMPLEMENTATION
${includes}

static const size_t memory_sizes[] = {
  ${sizes}
};

typedef struct recipe {
${fields}
  qip_render_workspace workspaces[${steps.length}];
} recipe;

static int recipe_init(recipe *r) {
  size_t i;
#if QIP_RECIPE_SHARED_WORKSPACE
  size_t largest = 0;
  size_t allocation_size;
  uint8_t *memory;
  for (i = 0; i < ${steps.length}; ++i)
    if (memory_sizes[i] > largest) largest = memory_sizes[i];
  allocation_size = qip_render_workspace_allocation_size(largest);
  memory = calloc(1, allocation_size);
  if (!memory) return 0;
  for (i = 0; i < ${steps.length}; ++i) {
    r->workspaces[i].memory = memory;
    r->workspaces[i].memory_size = largest;
  }
#else
  for (i = 0; i < ${steps.length}; ++i) {
    size_t allocation_size =
        qip_render_workspace_allocation_size(memory_sizes[i]);
    r->workspaces[i].memory = calloc(1, allocation_size);
    r->workspaces[i].memory_size = memory_sizes[i];
    if (!r->workspaces[i].memory) return 0;
  }
#endif
  return 1;
}

static int recipe_render(
    recipe *r,
    const uint8_t *input,
    uint32_t input_size,
    const uint8_t **output,
    uint32_t *output_size) {
  uint32_t offset = 0;
  uint32_t n = 0;
${renders}
  *output = r->workspaces[${steps.length - 1}].memory + offset;
  *output_size = n;
  return 1;
}

static uint64_t recipe_linear_memory(void) {
  uint64_t total = 0;
  size_t i;
#if QIP_RECIPE_SHARED_WORKSPACE
  for (i = 0; i < ${steps.length}; ++i)
    if (memory_sizes[i] > total) total = memory_sizes[i];
#else
  for (i = 0; i < ${steps.length}; ++i) total += memory_sizes[i];
#endif
  return total;
}

static void recipe_deinit(recipe *r) {
#if QIP_RECIPE_SHARED_WORKSPACE
  qip_render_workspace_clear(&r->workspaces[0]);
  free(r->workspaces[0].memory);
#else
${clears}
${frees}
#endif
}

int main(int argc, char **argv) {
  recipe r;
  uint8_t *input = NULL;
  uint32_t input_size = 0;
  const uint8_t *output = NULL;
  uint32_t output_size = 0;
  double *samples;
  double duration_ms;
  double deadline;
  size_t count = 0;
  uint64_t initial_rss, first_rss, final_rss;
  struct rusage usage;
  unsigned long warmup, i;

  if (argc < 3) {
    fprintf(stderr, "usage: generated-recipe input duration-ms [output] [warmup]\\n");
    return 2;
  }
  memset(&r, 0, sizeof(r));
  duration_ms = strtod(argv[2], NULL);
  warmup = argc > 4 ? strtoul(argv[4], NULL, 10) : 3;
  samples = malloc(MAX_SAMPLES * sizeof(*samples));
  if (!samples || !read_input(argv[1], &input, &input_size) || !recipe_init(&r))
    return 3;
  initial_rss = current_rss();
  for (i = 0; i < warmup; ++i) {
    if (!recipe_render(&r, input, input_size, &output, &output_size)) return 4;
    if (i == 0) first_rss = current_rss();
  }
  if (warmup == 0) first_rss = initial_rss;
  deadline = now_ms() + duration_ms;
  do {
    double start = now_ms();
    if (!recipe_render(&r, input, input_size, &output, &output_size)) return 5;
    samples[count++] = now_ms() - start;
  } while (count < MAX_SAMPLES && now_ms() < deadline);
  if (argc > 3 && !write_output(argv[3], output, output_size)) return 6;
  getrusage(RUSAGE_SELF, &usage);
  final_rss = current_rss();
  printf(
      "{\\"runtime\\":\\"qip-generated-c-recipe\\","
      "\\"memory\\":\\"%s\\",\\"steps\\":${steps.length},"
      "\\"input_bytes\\":%u,\\"output_bytes\\":%u,"
      "\\"linear_memory_bytes\\":%llu,"
      "\\"initial_rss_bytes\\":%llu,\\"first_rss_bytes\\":%llu,"
      "\\"final_rss_bytes\\":%llu,\\"max_rss_bytes\\":%llu,",
#if QIP_RECIPE_SHARED_WORKSPACE
      "shared-workspace",
#else
      "dedicated-workspaces",
#endif
      input_size,
      output_size,
      (unsigned long long)recipe_linear_memory(),
      (unsigned long long)initial_rss,
      (unsigned long long)first_rss,
      (unsigned long long)final_rss,
#if defined(__APPLE__)
      (unsigned long long)usage.ru_maxrss
#else
      (unsigned long long)usage.ru_maxrss * 1024u
#endif
  );
  print_summary(samples, count);
  printf("}\\n");
  recipe_deinit(&r);
  free(samples);
  free(input);
  return 0;
}
`;
}

function wasm2cSource() {
  const includes = steps
    .map(({ path }) => `#include ${quoted(path)}`)
    .join("\n");
  const fields = steps
    .map(({ prefix, index }) => `  ${prefix} step_${index + 1};`)
    .join("\n");
  const instantiate = steps
    .map(
      ({ module, index }) =>
        `  wasm2c_${module}_instantiate(&r->step_${index + 1});`,
    )
    .join("\n");
  const free = steps
    .map(
      ({ module, index }) => `  wasm2c_${module}_free(&r->step_${index + 1});`,
    )
    .join("\n");
  const memorySum = steps
    .map(
      ({ prefix, index }) =>
        `  total += ${prefix}_memory(&r->step_${index + 1})->size;`,
    )
    .join("\n");
  const renders = steps
    .map(({ prefix, inputCap, outputCap, index }) => {
      const n = index + 1;
      return `  memory = ${prefix}_memory(&r->step_${n});
  if (size > ${inputCap}(&r->step_${n})) return 0;
  input_offset = ${prefix}_input_ptr(&r->step_${n});
  if ((uint64_t)input_offset + size > memory->size) return 0;
  memcpy(memory->data + input_offset, bytes, size);
  size = ${prefix}_render(&r->step_${n}, size);
  if (size > ${outputCap}(&r->step_${n})) return 0;
  output_offset = ${prefix}_output_ptr(&r->step_${n});
  if ((uint64_t)output_offset + size > memory->size) return 0;
  bytes = memory->data + output_offset;`;
    })
    .join("\n\n");

  return `${commonPrefix}
${includes}

#if WASM_RT_USE_MMAP
#define ALLOCATION_MODE "mmap"
#else
#define ALLOCATION_MODE "calloc"
#endif
#if WASM_RT_MEMCHECK_GUARD_PAGES
#define MEMCHECK_MODE "guard-pages"
#else
#define MEMCHECK_MODE "explicit-bounds"
#endif

typedef struct recipe {
${fields}
} recipe;

static void recipe_init(recipe *r) {
${instantiate}
}

static void recipe_deinit(recipe *r) {
${free}
}

static uint64_t recipe_linear_memory(recipe *r) {
  uint64_t total = 0;
${memorySum}
  return total;
}

static int recipe_render(
    recipe *r,
    const uint8_t *input,
    uint32_t input_size,
    const uint8_t **output,
    uint32_t *output_size) {
  const uint8_t *bytes = input;
  uint32_t size = input_size;
  uint32_t input_offset, output_offset;
  wasm_rt_memory_t *memory;
${renders}
  *output = bytes;
  *output_size = size;
  return 1;
}

int main(int argc, char **argv) {
  recipe *r;
  uint8_t *input = NULL;
  uint32_t input_size = 0;
  const uint8_t *output = NULL;
  uint32_t output_size = 0;
  double *samples;
  double duration_ms;
  double deadline;
  size_t count = 0;
  uint64_t initial_rss, first_rss, final_rss;
  struct rusage usage;
  unsigned long warmup, i;

  if (argc < 3) {
    fprintf(stderr, "usage: wasm2c-recipe input duration-ms [output] [warmup]\\n");
    return 2;
  }
  duration_ms = strtod(argv[2], NULL);
  warmup = argc > 4 ? strtoul(argv[4], NULL, 10) : 3;
  r = calloc(1, sizeof(*r));
  samples = malloc(MAX_SAMPLES * sizeof(*samples));
  if (!r || !samples || !read_input(argv[1], &input, &input_size)) return 3;
  wasm_rt_init();
  recipe_init(r);
  initial_rss = current_rss();
  for (i = 0; i < warmup; ++i) {
    if (!recipe_render(r, input, input_size, &output, &output_size)) return 4;
    if (i == 0) first_rss = current_rss();
  }
  if (warmup == 0) first_rss = initial_rss;
  deadline = now_ms() + duration_ms;
  do {
    double start = now_ms();
    if (!recipe_render(r, input, input_size, &output, &output_size)) return 5;
    samples[count++] = now_ms() - start;
  } while (count < MAX_SAMPLES && now_ms() < deadline);
  if (argc > 3 && !write_output(argv[3], output, output_size)) return 6;
  getrusage(RUSAGE_SELF, &usage);
  final_rss = current_rss();
  printf(
      "{\\"runtime\\":\\"wabt-wasm2c-recipe\\","
      "\\"allocation\\":\\"%s\\",\\"memcheck\\":\\"%s\\","
      "\\"steps\\":${steps.length},"
      "\\"input_bytes\\":%u,\\"output_bytes\\":%u,"
      "\\"linear_memory_bytes\\":%llu,"
      "\\"initial_rss_bytes\\":%llu,\\"first_rss_bytes\\":%llu,"
      "\\"final_rss_bytes\\":%llu,\\"max_rss_bytes\\":%llu,",
      ALLOCATION_MODE,
      MEMCHECK_MODE,
      input_size,
      output_size,
      (unsigned long long)recipe_linear_memory(r),
      (unsigned long long)initial_rss,
      (unsigned long long)first_rss,
      (unsigned long long)final_rss,
#if defined(__APPLE__)
      (unsigned long long)usage.ru_maxrss
#else
      (unsigned long long)usage.ru_maxrss * 1024u
#endif
  );
  print_summary(samples, count);
  printf("}\\n");
  recipe_deinit(r);
  wasm_rt_free();
  free(samples);
  free(input);
  free(r);
  return 0;
}
`;
}

writeFileSync(outputPath, kind === "qip" ? qipSource() : wasm2cSource());
