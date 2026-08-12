#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

#define QIP_WASM_IMPLEMENTATION
#include QIP_WASM_HEADER_1
#include QIP_WASM_HEADER_2
#include QIP_WASM_HEADER_3

#define MAX_SAMPLES 10000u

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

typedef struct recipe {
    STEP_1_INSTANCE step_1;
    STEP_2_INSTANCE step_2;
    STEP_3_INSTANCE step_3;
    qip_render_workspace workspace;
} recipe;

static int recipe_render(
    recipe *r,
    const uint8_t *input,
    uint32_t input_size,
    uint32_t *output_offset,
    uint32_t *output_size) {
    uint32_t offset;
    uint32_t n;

    if (input_size > STEP_1_INPUT_CAPACITY) return 0;
    memcpy(r->workspace.memory + STEP_1_INPUT_OFFSET, input, input_size);
    if (STEP_1_INIT(&r->step_1, &r->workspace, input_size) != 0 ||
        STEP_1_RENDER(&r->step_1, input_size, &offset, &n) != 0) return 0;

    if (n > STEP_2_INPUT_CAPACITY) return 0;
    memmove(
        r->workspace.memory + STEP_2_INPUT_OFFSET,
        r->workspace.memory + offset,
        n);
    if (STEP_2_INIT(&r->step_2, &r->workspace, n) != 0 ||
        STEP_2_RENDER(&r->step_2, n, &offset, &n) != 0) return 0;

    if (n > STEP_3_INPUT_CAPACITY) return 0;
    memmove(
        r->workspace.memory + STEP_3_INPUT_OFFSET,
        r->workspace.memory + offset,
        n);
    if (STEP_3_INIT(&r->step_3, &r->workspace, n) != 0 ||
        STEP_3_RENDER(&r->step_3, n, &offset, &n) != 0) return 0;

    *output_offset = offset;
    *output_size = n;
    return 1;
}

int main(int argc, char **argv) {
    FILE *file;
    long file_size;
    uint8_t *input;
    uint8_t *allocation;
    double *samples;
    double duration_ms;
    double deadline;
    double sum = 0.0;
    size_t allocation_size;
    size_t count = 0;
    uint32_t output_offset = 0;
    uint32_t output_size = 0;
    uint64_t initial_rss;
    uint64_t first_rss;
    uint64_t final_rss;
    struct rusage usage;
    recipe r;
    int i;

    if (argc < 3) {
        fprintf(stderr, "usage: bench-content-c-workspace-recipe input duration-ms [output]\n");
        return 2;
    }
    memset(&r, 0, sizeof(r));
    duration_ms = strtod(argv[2], NULL);
    file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END) || (file_size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET)) return 3;
    input = malloc((size_t)file_size + 1);
    samples = malloc(MAX_SAMPLES * sizeof(*samples));
    allocation_size = qip_render_workspace_allocation_size(QIP_RECIPE_MEMORY_SIZE);
    allocation = calloc(1, allocation_size);
    if (!input || !samples || !allocation || !allocation_size) return 4;
    r.workspace.memory = allocation;
    r.workspace.memory_size = QIP_RECIPE_MEMORY_SIZE;
    if (fread(input, 1, (size_t)file_size, file) != (size_t)file_size) return 5;
    fclose(file);

    initial_rss = current_rss();
    if (!recipe_render(
            &r, input, (uint32_t)file_size, &output_offset, &output_size)) return 6;
    first_rss = current_rss();
    for (i = 1; i < 3; ++i) {
        if (!recipe_render(
                &r, input, (uint32_t)file_size, &output_offset, &output_size)) return 6;
    }

    deadline = now_ms() + duration_ms;
    do {
        double start = now_ms();
        if (!recipe_render(
                &r, input, (uint32_t)file_size, &output_offset, &output_size)) return 7;
        samples[count++] = now_ms() - start;
    } while (count < MAX_SAMPLES && now_ms() < deadline);

    if (argc > 3) {
        file = fopen(argv[3], "wb");
        if (!file ||
            fwrite(r.workspace.memory + output_offset, 1, output_size, file) != output_size)
            return 8;
        fclose(file);
    }
    getrusage(RUSAGE_SELF, &usage);
    final_rss = current_rss();
    qsort(samples, count, sizeof(*samples), compare_double);
    for (i = 0; i < (int)count; ++i) sum += samples[i];
    printf(
        "{\"runtime\":\"generated-c-image-recipe\","
        "\"memory\":\"workspace-in-place\",\"steps\":3,"
        "\"input_bytes\":%ld,\"output_bytes\":%u,"
        "\"workspace_memory_bytes\":%llu,\"workspace_allocation_bytes\":%llu,"
        "\"initial_rss_bytes\":%llu,\"first_rss_bytes\":%llu,"
        "\"final_rss_bytes\":%llu,\"max_rss_bytes\":%lld,"
        "\"warm_recipe\":{\"samples\":%zu,\"mean_ms\":%.9f,"
        "\"p50_ms\":%.9f,\"p95_ms\":%.9f,\"max_ms\":%.9f}}\n",
        file_size,
        output_size,
        (unsigned long long)QIP_RECIPE_MEMORY_SIZE,
        (unsigned long long)allocation_size,
        (unsigned long long)initial_rss,
        (unsigned long long)first_rss,
        (unsigned long long)final_rss,
#if defined(__APPLE__)
        (long long)usage.ru_maxrss,
#else
        (long long)usage.ru_maxrss * 1024,
#endif
        count,
        sum / (double)count,
        samples[count / 2],
        samples[(count * 95) / 100],
        samples[count - 1]);

    qip_render_workspace_clear(&r.workspace);
    free(allocation);
    free(samples);
    free(input);
    return 0;
}
