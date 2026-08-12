#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

#define MAX_SAMPLES 1000000u

extern size_t qip_native_output_capacity(void);
extern uint32_t qip_native_render(
    const uint8_t *input,
    size_t input_size,
    uint8_t *output,
    size_t output_capacity);

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

int main(int argc, char **argv) {
    FILE *file;
    long file_size;
    size_t output_capacity;
    uint8_t *input;
    uint8_t *output;
    double *samples;
    double duration_ms;
    double deadline;
    size_t count = 0;
    uint32_t output_size = 0;
    struct rusage usage;
    int i;

    if (argc < 3) {
        fprintf(stderr, "usage: bench-content-native input duration-ms [output]\n");
        return 2;
    }
    duration_ms = strtod(argv[2], NULL);
    file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END) ||
        (file_size = ftell(file)) < 0 || fseek(file, 0, SEEK_SET)) return 3;
    output_capacity = qip_native_output_capacity();
    input = malloc((size_t)file_size + 1);
    output = malloc(output_capacity);
    samples = malloc(MAX_SAMPLES * sizeof(*samples));
    if (!input || !output || !samples) return 4;
    if (fread(input, 1, (size_t)file_size, file) != (size_t)file_size) return 5;
    fclose(file);

    for (i = 0; i < 20; ++i) {
        output_size =
            qip_native_render(input, (size_t)file_size, output, output_capacity);
    }

    deadline = now_ms() + duration_ms;
    do {
        double start = now_ms();
        output_size =
            qip_native_render(input, (size_t)file_size, output, output_capacity);
        samples[count++] = now_ms() - start;
    } while (count < MAX_SAMPLES && now_ms() < deadline);

    if (argc > 3) {
        file = fopen(argv[3], "wb");
        if (!file || fwrite(output, 1, output_size, file) != output_size) return 6;
        fclose(file);
    }

    getrusage(RUSAGE_SELF, &usage);
    printf(
        "{\"runtime\":\"source-native\",\"input_bytes\":%ld,"
        "\"output_bytes\":%u,\"max_rss_bytes\":%lld,",
        file_size,
        output_size,
#if defined(__APPLE__)
        (long long)usage.ru_maxrss
#else
        (long long)usage.ru_maxrss * 1024
#endif
    );
    print_summary("warm_full", samples, count);
    printf("}\n");

    free(samples);
    free(output);
    free(input);
    return 0;
}
