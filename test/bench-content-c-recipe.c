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
#include QIP_WASM_HEADER_4
#include QIP_WASM_HEADER_5

#define BUFFER_CAPACITY (16u * 1024u * 1024u)
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

static void print_summary(double *samples, size_t count) {
    double sum = 0.0;
    size_t i;
    for (i = 0; i < count; ++i) sum += samples[i];
    qsort(samples, count, sizeof(*samples), compare_double);
    printf(
        "\"warm_recipe\":{\"samples\":%zu,\"mean_ms\":%.9f,"
        "\"p50_ms\":%.9f,\"p95_ms\":%.9f,\"max_ms\":%.9f}",
        count,
        sum / (double)count,
        samples[count / 2],
        samples[(count * 95) / 100],
        samples[count - 1]);
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
    STEP_4_INSTANCE step_4;
    STEP_5_INSTANCE step_5;
    qip_render_workspace workspace_1;
    qip_render_workspace workspace_2;
    qip_render_workspace workspace_3;
    qip_render_workspace workspace_4;
    qip_render_workspace workspace_5;
} recipe;

static int recipe_init(recipe *r) {
#if QIP_RECIPE_SHARED_ARENA
    uint8_t *memory = calloc(
        1,
        qip_render_workspace_allocation_size((size_t)QIP_RECIPE_MEMORY_SIZE));
    if (!memory) return 0;
    r->workspace_1 = (qip_render_workspace){
        memory, (size_t)QIP_RECIPE_MEMORY_SIZE};
    r->workspace_2 = r->workspace_1;
    r->workspace_3 = r->workspace_1;
    r->workspace_4 = r->workspace_1;
    r->workspace_5 = r->workspace_1;
#else
    r->workspace_1 = (qip_render_workspace){
        calloc(1, qip_render_workspace_allocation_size(STEP_1_MEMORY_SIZE)),
        STEP_1_MEMORY_SIZE};
    r->workspace_2 = (qip_render_workspace){
        calloc(1, qip_render_workspace_allocation_size(STEP_2_MEMORY_SIZE)),
        STEP_2_MEMORY_SIZE};
    r->workspace_3 = (qip_render_workspace){
        calloc(1, qip_render_workspace_allocation_size(STEP_3_MEMORY_SIZE)),
        STEP_3_MEMORY_SIZE};
    r->workspace_4 = (qip_render_workspace){
        calloc(1, qip_render_workspace_allocation_size(STEP_4_MEMORY_SIZE)),
        STEP_4_MEMORY_SIZE};
    r->workspace_5 = (qip_render_workspace){
        calloc(1, qip_render_workspace_allocation_size(STEP_5_MEMORY_SIZE)),
        STEP_5_MEMORY_SIZE};
    if (!r->workspace_1.memory || !r->workspace_2.memory ||
        !r->workspace_3.memory || !r->workspace_4.memory ||
        !r->workspace_5.memory) return 0;
#endif
    return 1;
}

static int recipe_render(
    recipe *r,
    const uint8_t *input,
    uint32_t input_size,
    uint8_t *buffer_a,
    uint8_t *buffer_b,
    uint32_t *output_size) {
    uint32_t offset = 0;
    uint32_t n = 0;
#define RUN_STEP(number, input_bytes, input_length, output_bytes)                 \
    do {                                                                          \
        if ((input_length) > STEP_##number##_INPUT_CAPACITY) return 0;            \
        memcpy(                                                                   \
            r->workspace_##number.memory + STEP_##number##_INPUT_OFFSET,          \
            input_bytes,                                                          \
            input_length);                                                        \
        if (STEP_##number##_INIT(                                                 \
                &r->step_##number,                                                \
                &r->workspace_##number,                                           \
                input_length) != 0) return 0;                                     \
        if (STEP_##number##_RENDER(                                               \
                &r->step_##number,                                                \
                input_length,                                                     \
                &offset,                                                          \
                &n) != 0) return 0;                                               \
        if (n > BUFFER_CAPACITY) return 0;                                        \
        memcpy(                                                                   \
            output_bytes,                                                         \
            r->workspace_##number.memory + offset,                                \
            n);                                                                   \
    } while (0)

    RUN_STEP(1, input, input_size, buffer_a);
    RUN_STEP(2, buffer_a, n, buffer_b);
    RUN_STEP(3, buffer_b, n, buffer_a);
    RUN_STEP(4, buffer_a, n, buffer_b);
    RUN_STEP(5, buffer_b, n, buffer_a);
#undef RUN_STEP
    *output_size = n;
    return 1;
}

static void recipe_deinit(recipe *r) {
#if QIP_RECIPE_SHARED_ARENA
    qip_render_workspace_clear(&r->workspace_1);
    free(r->workspace_1.memory);
#else
    qip_render_workspace_clear(&r->workspace_1);
    qip_render_workspace_clear(&r->workspace_2);
    qip_render_workspace_clear(&r->workspace_3);
    qip_render_workspace_clear(&r->workspace_4);
    qip_render_workspace_clear(&r->workspace_5);
    free(r->workspace_1.memory);
    free(r->workspace_2.memory);
    free(r->workspace_3.memory);
    free(r->workspace_4.memory);
    free(r->workspace_5.memory);
#endif
}

int main(int argc, char **argv) {
    FILE *file;
    long file_size;
    uint8_t *input;
    uint8_t *buffer_a;
    uint8_t *buffer_b;
    double *samples;
    double duration_ms;
    double deadline;
    size_t count = 0;
    uint32_t output_size = 0;
    uint64_t initial_rss;
    uint64_t first_rss;
    uint64_t final_rss;
    struct rusage usage;
    recipe r;
    int i;

    if (argc < 3) {
        fprintf(stderr, "usage: bench-content-c-recipe input duration-ms [output]\n");
        return 2;
    }
    memset(&r, 0, sizeof(r));
    duration_ms = strtod(argv[2], NULL);
    file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END) || (file_size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET)) return 3;
    input = malloc((size_t)file_size + 1);
    buffer_a = malloc(BUFFER_CAPACITY);
    buffer_b = malloc(BUFFER_CAPACITY);
    samples = malloc(MAX_SAMPLES * sizeof(*samples));
    if (!input || !buffer_a || !buffer_b || !samples || !recipe_init(&r)) return 4;
    if (fread(input, 1, (size_t)file_size, file) != (size_t)file_size) return 5;
    fclose(file);

    initial_rss = current_rss();
    if (!recipe_render(
            &r,
            input,
            (uint32_t)file_size,
            buffer_a,
            buffer_b,
            &output_size)) return 6;
    first_rss = current_rss();
    for (i = 1; i < 20; ++i) {
        if (!recipe_render(
                &r,
                input,
                (uint32_t)file_size,
                buffer_a,
                buffer_b,
                &output_size)) return 6;
    }

    deadline = now_ms() + duration_ms;
    do {
        double start = now_ms();
        if (!recipe_render(
                &r,
                input,
                (uint32_t)file_size,
                buffer_a,
                buffer_b,
                &output_size)) return 7;
        samples[count++] = now_ms() - start;
    } while (count < MAX_SAMPLES && now_ms() < deadline);

    if (argc > 3) {
        file = fopen(argv[3], "wb");
        if (!file || fwrite(buffer_a, 1, output_size, file) != output_size) return 8;
        fclose(file);
    }
    getrusage(RUSAGE_SELF, &usage);
    final_rss = current_rss();
    printf(
        "{\"runtime\":\"generated-c-recipe\",\"memory\":\"%s\","
        "\"steps\":5,\"input_bytes\":%ld,\"output_bytes\":%u,"
        "\"arena_bytes\":%llu,\"dedicated_memory_bytes\":%llu,"
        "\"initial_rss_bytes\":%llu,\"first_rss_bytes\":%llu,"
        "\"final_rss_bytes\":%llu,\"max_rss_bytes\":%lld,",
#if QIP_RECIPE_SHARED_ARENA
        "shared-arena",
#else
        "dedicated",
#endif
        file_size,
        output_size,
        (unsigned long long)QIP_RECIPE_MEMORY_SIZE,
        (unsigned long long)(
            STEP_1_MEMORY_SIZE + STEP_2_MEMORY_SIZE + STEP_3_MEMORY_SIZE +
            STEP_4_MEMORY_SIZE + STEP_5_MEMORY_SIZE),
        (unsigned long long)initial_rss,
        (unsigned long long)first_rss,
        (unsigned long long)final_rss,
#if defined(__APPLE__)
        (long long)usage.ru_maxrss
#else
        (long long)usage.ru_maxrss * 1024
#endif
    );
    print_summary(samples, count);
    printf("}\n");

    recipe_deinit(&r);
    free(samples);
    free(buffer_b);
    free(buffer_a);
    free(input);
    return 0;
}
