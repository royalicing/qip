#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

#define QIP_WASM_GENERIC_API
#define QIP_WASM_IMPLEMENTATION
#include QIP_WASM_GENERATED_HEADER

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
    qip_wasm_instance *instance,
    qip_render_workspace *workspace,
    const uint8_t *input,
    uint8_t *output,
    uint32_t input_size,
    uint32_t *output_offset,
    uint32_t *output_size) {
    qip_wasm_status status;
    memcpy(workspace->memory + QIP_WASM_INPUT_OFFSET, input, input_size);
    status = qip_wasm_render(
        instance,
        input_size,
        output_offset,
        output_size);
    if (status != QIP_WASM_OK) return 0;
    memcpy(output, workspace->memory + *output_offset, *output_size);
    return 1;
}

int main(int argc, char **argv) {
    FILE *file;
    long file_size;
    uint8_t *input;
    uint8_t *output;
    uint8_t *memory;
    qip_render_workspace workspace;
    qip_wasm_instance *instance;
    double *warm_samples;
    double *cold_samples;
    double duration_ms;
    double deadline;
    size_t warm_count = 0;
    size_t cold_count = 0;
    uint32_t output_size = 0;
    uint32_t output_offset = 0;
    int i;
    struct rusage usage;
    uint64_t initial_rss_bytes;
    uint64_t initial_virtual_bytes;
    uint64_t first_render_rss_bytes;
    uint64_t first_render_virtual_bytes;
    uint64_t before_reset_rss_bytes;
    uint64_t before_reset_virtual_bytes;
    uint64_t after_reset_rss_bytes;
    uint64_t after_reset_virtual_bytes;
    uint64_t current_rss_bytes;
    uint64_t current_virtual_bytes;
    uint32_t dirty_pages;
    uint32_t reset_pages;
    double reset_start;
    double reset_ms;

    if (argc < 3) {
        fprintf(stderr, "usage: bench-content-c input duration-ms [output]\n");
        return 2;
    }
    duration_ms = strtod(argv[2], NULL);
    file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END) || (file_size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET)) return 3;
    input = malloc((size_t)file_size + 1);
    output = malloc((size_t)QIP_WASM_OUTPUT_CAPACITY);
    memory = calloc(
        1,
        qip_render_workspace_allocation_size((size_t)QIP_WASM_MEMORY_SIZE));
    instance = malloc(sizeof(*instance));
    warm_samples = malloc(MAX_SAMPLES * sizeof(*warm_samples));
    cold_samples = malloc(MAX_SAMPLES * sizeof(*cold_samples));
    if (!input || !output || !memory || !instance || !warm_samples ||
        !cold_samples) return 4;
    workspace = (qip_render_workspace){memory, (size_t)QIP_WASM_MEMORY_SIZE};
    if (fread(input, 1, (size_t)file_size, file) != (size_t)file_size) return 5;
    fclose(file);

    memcpy(workspace.memory + QIP_WASM_INPUT_OFFSET, input, (size_t)file_size);
    if (qip_wasm_init(instance, &workspace, (uint32_t)file_size) !=
        QIP_WASM_OK) return 6;
    current_process_memory(&initial_rss_bytes, &initial_virtual_bytes);
    if (!render_once(instance, &workspace, input, output, (uint32_t)file_size, &output_offset, &output_size)) return 6;
    current_process_memory(&first_render_rss_bytes, &first_render_virtual_bytes);
    for (i = 1; i < 20; ++i) {
        if (!render_once(instance, &workspace, input, output, (uint32_t)file_size, &output_offset, &output_size)) return 6;
    }

    deadline = now_ms() + duration_ms;
    do {
        double start = now_ms();
        if (!render_once(instance, &workspace, input, output, (uint32_t)file_size, &output_offset, &output_size)) return 7;
        warm_samples[warm_count++] = now_ms() - start;
    } while (warm_count < MAX_SAMPLES && now_ms() < deadline);

    dirty_pages = qip_wasm_dirty_page_count(instance);
    current_process_memory(&before_reset_rss_bytes, &before_reset_virtual_bytes);
    reset_start = now_ms();
    reset_pages = qip_render_workspace_clear(&workspace);
    reset_ms = now_ms() - reset_start;
    current_process_memory(&after_reset_rss_bytes, &after_reset_virtual_bytes);

    deadline = now_ms() + duration_ms;
    do {
        double start = now_ms();
        memcpy(workspace.memory + QIP_WASM_INPUT_OFFSET, input, (size_t)file_size);
        if (qip_wasm_init(instance, &workspace, (uint32_t)file_size) !=
            QIP_WASM_OK) return 8;
        if (!render_once(instance, &workspace, input, output, (uint32_t)file_size, &output_offset, &output_size)) return 8;
        cold_samples[cold_count++] = now_ms() - start;
    } while (cold_count < MAX_SAMPLES && now_ms() < deadline);

    if (argc > 3) {
        file = fopen(argv[3], "wb");
        if (!file ||
            fwrite(output, 1, output_size, file) != output_size)
            return 9;
        fclose(file);
    }

    getrusage(RUSAGE_SELF, &usage);
    current_process_memory(&current_rss_bytes, &current_virtual_bytes);
    printf(
        "{\"runtime\":\"generated-c\",\"input_bytes\":%ld,\"output_bytes\":%u,"
        "\"dirty_tracking\":%d,\"dirty_pages\":%u,\"reset_pages\":%u,"
        "\"reset_ms\":%.9f,"
        "\"instance_bytes\":%zu,\"linear_memory_bytes\":%llu,"
        "\"max_rss_bytes\":%lld,\"initial_rss_bytes\":%llu,"
        "\"initial_virtual_bytes\":%llu,\"first_render_rss_bytes\":%llu,"
        "\"first_render_virtual_bytes\":%llu,\"before_reset_rss_bytes\":%llu,"
        "\"before_reset_virtual_bytes\":%llu,\"after_reset_rss_bytes\":%llu,"
        "\"after_reset_virtual_bytes\":%llu,\"current_rss_bytes\":%llu,"
        "\"current_virtual_bytes\":%llu,",
        file_size,
        output_size,
        QIP_WASM_DIRTY_TRACKING,
        dirty_pages,
        reset_pages,
        reset_ms,
        sizeof(*instance),
        (unsigned long long)QIP_WASM_MEMORY_SIZE,
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
        (unsigned long long)before_reset_rss_bytes,
        (unsigned long long)before_reset_virtual_bytes,
        (unsigned long long)after_reset_rss_bytes,
        (unsigned long long)after_reset_virtual_bytes,
        (unsigned long long)current_rss_bytes,
        (unsigned long long)current_virtual_bytes
    );
    print_summary("warm_full", warm_samples, warm_count);
    printf(",");
    print_summary("reset_init_full", cold_samples, cold_count);
    printf("}\n");

    qip_render_workspace_clear(&workspace);
    free(cold_samples);
    free(warm_samples);
    free(instance);
    free(memory);
    free(output);
    free(input);
    return 0;
}
