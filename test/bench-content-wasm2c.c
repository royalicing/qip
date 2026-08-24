#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

#include WASM2C_GENERATED_HEADER

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

static void print_summary(const char *name, double *samples, size_t count) {
    double sum = 0.0;
    size_t i;
    for (i = 0; i < count; ++i) sum += samples[i];
    qsort(samples, count, sizeof(*samples), compare_double);
    printf(
        "\"%s\":{\"samples\":%zu,\"mean_ms\":%.9f,\"p50_ms\":%.9f,"
        "\"p95_ms\":%.9f,\"max_ms\":%.9f}",
        name,
        count,
        sum / (double)count,
        samples[count / 2],
        samples[(count * 95) / 100],
        samples[count - 1]);
}

static void current_process_memory(
    uint64_t *resident_bytes,
    uint64_t *virtual_bytes) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(
        mach_task_self(),
        MACH_TASK_BASIC_INFO,
        (task_info_t)&info,
        &count);
    if (result == KERN_SUCCESS) {
        *resident_bytes = info.resident_size;
        *virtual_bytes = info.virtual_size;
        return;
    }
#endif
    *resident_bytes = 0;
    *virtual_bytes = 0;
}

static int render_once(
    w2c_qipbench *instance,
    const uint8_t *input,
    uint32_t input_size,
    uint8_t *output,
    uint32_t *output_size) {
    wasm_rt_memory_t *memory = w2c_qipbench_memory(instance);
    uint32_t input_ptr = w2c_qipbench_input_ptr(instance);
    uint32_t output_ptr;
    uint64_t result;
    memcpy(memory->data + input_ptr, input, input_size);
    result = w2c_qipbench_render(instance, input_size);
    if ((result >> 63) != 0) return 0;
    *output_size = (uint32_t)result;
    output_ptr = (uint32_t)((result >> 32) & UINT64_C(0x7fffffff));
    memcpy(output, memory->data + output_ptr, *output_size);
    return 1;
}

int main(int argc, char **argv) {
    FILE *file;
    long file_size;
    uint8_t *input;
    uint8_t *output;
    w2c_qipbench *instance;
    double *warm_samples;
    double *cold_samples;
    double duration_ms;
    double deadline;
    size_t warm_count = 0;
    size_t cold_count = 0;
    uint32_t output_size = 0;
    int i;
    struct rusage usage;
    uint64_t initial_rss_bytes;
    uint64_t initial_virtual_bytes;
    uint64_t first_render_rss_bytes;
    uint64_t first_render_virtual_bytes;
    uint64_t current_rss_bytes;
    uint64_t current_virtual_bytes;

    if (argc < 3) {
        fprintf(stderr, "usage: bench-content-wasm2c input duration-ms [output]\n");
        return 2;
    }
    duration_ms = strtod(argv[2], NULL);
    file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END) || (file_size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET)) return 3;
    input = malloc((size_t)file_size + 1);
    output = malloc(512u * 1024u * 1024u);
    instance = malloc(sizeof(*instance));
    warm_samples = malloc(MAX_SAMPLES * sizeof(*warm_samples));
    cold_samples = malloc(MAX_SAMPLES * sizeof(*cold_samples));
    if (!input || !output || !instance || !warm_samples || !cold_samples) return 4;
    if (fread(input, 1, (size_t)file_size, file) != (size_t)file_size) return 5;
    fclose(file);

    wasm_rt_init();
    wasm2c_qipbench_instantiate(instance);
    current_process_memory(&initial_rss_bytes, &initial_virtual_bytes);
    if (!render_once(instance, input, (uint32_t)file_size, output, &output_size)) return 6;
    current_process_memory(&first_render_rss_bytes, &first_render_virtual_bytes);
    for (i = 1; i < 20; ++i)
        if (!render_once(instance, input, (uint32_t)file_size, output, &output_size)) return 6;

    deadline = now_ms() + duration_ms;
    do {
        double start = now_ms();
        if (!render_once(instance, input, (uint32_t)file_size, output, &output_size)) return 7;
        warm_samples[warm_count++] = now_ms() - start;
    } while (warm_count < MAX_SAMPLES && now_ms() < deadline);
    wasm2c_qipbench_free(instance);

    deadline = now_ms() + duration_ms;
    do {
        double start = now_ms();
        wasm2c_qipbench_instantiate(instance);
        if (!render_once(instance, input, (uint32_t)file_size, output, &output_size)) return 8;
        wasm2c_qipbench_free(instance);
        cold_samples[cold_count++] = now_ms() - start;
    } while (cold_count < MAX_SAMPLES && now_ms() < deadline);

    wasm2c_qipbench_instantiate(instance);
    if (!render_once(instance, input, (uint32_t)file_size, output, &output_size)) return 8;
    if (argc > 3) {
        file = fopen(argv[3], "wb");
        if (!file || fwrite(output, 1, output_size, file) != output_size) return 9;
        fclose(file);
    }
    getrusage(RUSAGE_SELF, &usage);
    current_process_memory(&current_rss_bytes, &current_virtual_bytes);
    printf(
        "{\"runtime\":\"wabt-wasm2c\",\"allocation\":\"%s\","
        "\"memcheck\":\"%s\",\"input_bytes\":%ld,\"output_bytes\":%u,"
        "\"linear_memory_bytes\":%llu,\"max_rss_bytes\":%lld,"
        "\"initial_rss_bytes\":%llu,\"initial_virtual_bytes\":%llu,"
        "\"first_render_rss_bytes\":%llu,\"first_render_virtual_bytes\":%llu,"
        "\"current_rss_bytes\":%llu,\"current_virtual_bytes\":%llu,",
        WASM2C_ALLOCATION_MODE,
        WASM2C_MEMCHECK_MODE,
        file_size,
        output_size,
        (unsigned long long)instance->w2c_memory.size,
#if defined(__APPLE__)
        (long long)usage.ru_maxrss
#else
        (long long)usage.ru_maxrss * 1024
#endif
        ,
        (unsigned long long)initial_rss_bytes,
        (unsigned long long)initial_virtual_bytes,
        (unsigned long long)first_render_rss_bytes,
        (unsigned long long)first_render_virtual_bytes,
        (unsigned long long)current_rss_bytes,
        (unsigned long long)current_virtual_bytes
    );
    print_summary("warm_full", warm_samples, warm_count);
    printf(",");
    print_summary("cold_instantiate_full", cold_samples, cold_count);
    printf("}\n");

    wasm2c_qipbench_free(instance);
    wasm_rt_free();
    free(cold_samples);
    free(warm_samples);
    free(instance);
    free(output);
    free(input);
    return 0;
}
