#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

#include WASM2C_HEADER_1
#include WASM2C_HEADER_2
#include WASM2C_HEADER_3
#ifndef QIP_RECIPE_STEP_COUNT
#define QIP_RECIPE_STEP_COUNT 5
#endif
#if QIP_RECIPE_STEP_COUNT != 3 && QIP_RECIPE_STEP_COUNT != 5
#error "QIP_RECIPE_STEP_COUNT must be 3 or 5"
#endif
#if QIP_RECIPE_STEP_COUNT >= 4
#include WASM2C_HEADER_4
#endif
#if QIP_RECIPE_STEP_COUNT >= 5
#include WASM2C_HEADER_5
#endif

#ifndef BUFFER_CAPACITY
#define BUFFER_CAPACITY (16u * 1024u * 1024u)
#endif
#ifndef QIP_RECIPE_DIRECT_HANDOFF
#define QIP_RECIPE_DIRECT_HANDOFF 0
#endif
#if QIP_RECIPE_DIRECT_HANDOFF && QIP_RECIPE_STEP_COUNT != 3
#error "direct handoff is currently implemented for three-step recipes"
#endif
#define MAX_SAMPLES 1000000u

#if WASM_RT_USE_MMAP
#define WASM2C_ALLOCATION_MODE "mmap"
#else
#define WASM2C_ALLOCATION_MODE "calloc"
#endif

#if WASM_RT_MEMCHECK_GUARD_PAGES
#define WASM2C_MEMCHECK_MODE "guard-pages"
#else
#define WASM2C_MEMCHECK_MODE "explicit-bounds"
#endif

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

#define DEFINE_RENDER(number)                                                     \
    static uint32_t render_##number(                                              \
        STEP_##number##_INSTANCE *instance,                                       \
        const uint8_t *input,                                                     \
        uint32_t input_size,                                                      \
        uint8_t *output) {                                                        \
        wasm_rt_memory_t *memory = STEP_##number##_MEMORY(instance);              \
        uint32_t input_ptr = STEP_##number##_INPUT_PTR(instance);                 \
        uint32_t output_size;                                                     \
        uint32_t output_ptr;                                                      \
        uint64_t result;                                                          \
        memcpy(memory->data + input_ptr, input, input_size);                      \
        result = STEP_##number##_RENDER(instance, input_size);                    \
        if ((result >> 63) != 0) {                                                \
            fputs("recipe component rejected its input\n", stderr);              \
            exit(7);                                                              \
        }                                                                         \
        output_size = (uint32_t)result;                                           \
        output_ptr = (uint32_t)((result >> 32) & UINT64_C(0x7fffffff));           \
        memcpy(output, memory->data + output_ptr, output_size);                   \
        return output_size;                                                       \
    }

DEFINE_RENDER(1)
DEFINE_RENDER(2)
DEFINE_RENDER(3)
#if QIP_RECIPE_STEP_COUNT >= 4
DEFINE_RENDER(4)
#endif
#if QIP_RECIPE_STEP_COUNT >= 5
DEFINE_RENDER(5)
#endif

#if QIP_RECIPE_DIRECT_HANDOFF
#define DEFINE_DIRECT_RENDER(number)                                              \
    static uint32_t render_direct_##number(                                      \
        STEP_##number##_INSTANCE *instance,                                      \
        const uint8_t *input,                                                    \
        uint32_t input_size,                                                     \
        const uint8_t **output) {                                                \
        wasm_rt_memory_t *memory = STEP_##number##_MEMORY(instance);             \
        uint32_t input_ptr = STEP_##number##_INPUT_PTR(instance);                \
        uint32_t output_size;                                                    \
        uint32_t output_ptr;                                                     \
        uint64_t result;                                                         \
        memcpy(memory->data + input_ptr, input, input_size);                     \
        result = STEP_##number##_RENDER(instance, input_size);                   \
        if ((result >> 63) != 0) {                                               \
            fputs("recipe component rejected its input\n", stderr);             \
            exit(7);                                                             \
        }                                                                        \
        output_size = (uint32_t)result;                                          \
        output_ptr = (uint32_t)((result >> 32) & UINT64_C(0x7fffffff));          \
        *output = memory->data + output_ptr;                                     \
        return output_size;                                                      \
    }

DEFINE_DIRECT_RENDER(1)
DEFINE_DIRECT_RENDER(2)
DEFINE_DIRECT_RENDER(3)
#endif

typedef struct recipe {
    STEP_1_INSTANCE step_1;
    STEP_2_INSTANCE step_2;
    STEP_3_INSTANCE step_3;
#if QIP_RECIPE_STEP_COUNT >= 4
    STEP_4_INSTANCE step_4;
#endif
#if QIP_RECIPE_STEP_COUNT >= 5
    STEP_5_INSTANCE step_5;
#endif
} recipe;

static void recipe_init(recipe *r) {
    STEP_1_INSTANTIATE(&r->step_1);
    STEP_2_INSTANTIATE(&r->step_2);
    STEP_3_INSTANTIATE(&r->step_3);
#if QIP_RECIPE_STEP_COUNT >= 4
    STEP_4_INSTANTIATE(&r->step_4);
#endif
#if QIP_RECIPE_STEP_COUNT >= 5
    STEP_5_INSTANTIATE(&r->step_5);
#endif
}

static uint32_t recipe_render(
    recipe *r,
    const uint8_t *input,
    uint32_t input_size,
    uint8_t *buffer_a,
    uint8_t *buffer_b,
    const uint8_t **output) {
    uint32_t n;
#if QIP_RECIPE_DIRECT_HANDOFF
    const uint8_t *bytes;
    (void)buffer_a;
    (void)buffer_b;
    n = render_direct_1(&r->step_1, input, input_size, &bytes);
    n = render_direct_2(&r->step_2, bytes, n, &bytes);
    return render_direct_3(&r->step_3, bytes, n, output);
#else
    n = render_1(&r->step_1, input, input_size, buffer_a);
    n = render_2(&r->step_2, buffer_a, n, buffer_b);
#if QIP_RECIPE_STEP_COUNT == 3
    n = render_3(&r->step_3, buffer_b, n, buffer_a);
#else
    n = render_3(&r->step_3, buffer_b, n, buffer_a);
    n = render_4(&r->step_4, buffer_a, n, buffer_b);
    n = render_5(&r->step_5, buffer_b, n, buffer_a);
#endif
    *output = buffer_a;
    return n;
#endif
}

static void recipe_free(recipe *r) {
    STEP_1_FREE(&r->step_1);
    STEP_2_FREE(&r->step_2);
    STEP_3_FREE(&r->step_3);
#if QIP_RECIPE_STEP_COUNT >= 4
    STEP_4_FREE(&r->step_4);
#endif
#if QIP_RECIPE_STEP_COUNT >= 5
    STEP_5_FREE(&r->step_5);
#endif
}

static uint64_t recipe_memory_size(recipe *r) {
    uint64_t result =
        STEP_1_MEMORY(&r->step_1)->size +
        STEP_2_MEMORY(&r->step_2)->size +
        STEP_3_MEMORY(&r->step_3)->size;
#if QIP_RECIPE_STEP_COUNT >= 4
    result += STEP_4_MEMORY(&r->step_4)->size;
#endif
#if QIP_RECIPE_STEP_COUNT >= 5
    result += STEP_5_MEMORY(&r->step_5)->size;
#endif
    return result;
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
    uint32_t output_size;
    const uint8_t *output;
    uint64_t initial_rss;
    uint64_t first_rss;
    uint64_t final_rss;
    struct rusage usage;
    recipe *r;
    int i;

    if (argc < 3) {
        fprintf(stderr, "usage: bench-content-wasm2c-recipe input duration-ms [output]\n");
        return 2;
    }
    duration_ms = strtod(argv[2], NULL);
    file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END) || (file_size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET)) return 3;
    input = malloc((size_t)file_size + 1);
#if QIP_RECIPE_DIRECT_HANDOFF
    buffer_a = NULL;
    buffer_b = NULL;
#else
    buffer_a = malloc(BUFFER_CAPACITY);
    buffer_b = malloc(BUFFER_CAPACITY);
#endif
    samples = malloc(MAX_SAMPLES * sizeof(*samples));
    r = malloc(sizeof(*r));
    if (!input || !samples || !r) return 4;
#if !QIP_RECIPE_DIRECT_HANDOFF
    if (!buffer_a || !buffer_b) return 4;
#endif
    if (fread(input, 1, (size_t)file_size, file) != (size_t)file_size) return 5;
    fclose(file);

    wasm_rt_init();
    recipe_init(r);
    initial_rss = current_rss();
    output_size = recipe_render(
        r, input, (uint32_t)file_size, buffer_a, buffer_b, &output);
    first_rss = current_rss();
    for (i = 1; i < 20; ++i)
        output_size = recipe_render(
            r, input, (uint32_t)file_size, buffer_a, buffer_b, &output);

    deadline = now_ms() + duration_ms;
    do {
        double start = now_ms();
        output_size = recipe_render(
            r, input, (uint32_t)file_size, buffer_a, buffer_b, &output);
        samples[count++] = now_ms() - start;
    } while (count < MAX_SAMPLES && now_ms() < deadline);

    if (argc > 3) {
        file = fopen(argv[3], "wb");
        if (!file || fwrite(output, 1, output_size, file) != output_size) return 6;
        fclose(file);
    }
    getrusage(RUSAGE_SELF, &usage);
    final_rss = current_rss();
    printf(
        "{\"runtime\":\"wabt-wasm2c-recipe\",\"allocation\":\"%s\","
        "\"memcheck\":\"%s\",\"steps\":%d,\"input_bytes\":%ld,"
        "\"output_bytes\":%u,\"linear_memory_bytes\":%llu,"
        "\"initial_rss_bytes\":%llu,\"first_rss_bytes\":%llu,"
        "\"final_rss_bytes\":%llu,\"max_rss_bytes\":%lld,",
        WASM2C_ALLOCATION_MODE,
        WASM2C_MEMCHECK_MODE,
        QIP_RECIPE_STEP_COUNT,
        file_size,
        output_size,
        (unsigned long long)recipe_memory_size(r),
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

    recipe_free(r);
    wasm_rt_free();
    free(r);
    free(samples);
    free(buffer_b);
    free(buffer_a);
    free(input);
    return 0;
}
