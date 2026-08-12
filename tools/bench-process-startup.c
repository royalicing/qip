#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

typedef struct sample {
    double milliseconds;
    uint64_t max_rss_bytes;
} sample;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static int compare_time(const void *a, const void *b) {
    const sample *left = a;
    const sample *right = b;
    return (left->milliseconds > right->milliseconds) -
           (left->milliseconds < right->milliseconds);
}

static int run_once(
    const char *input_path,
    char *const command[],
    sample *result) {
    posix_spawn_file_actions_t actions;
    struct rusage usage;
    double start;
    pid_t child;
    int status;
    int error;

    if (posix_spawn_file_actions_init(&actions) != 0) return 0;
    if (posix_spawn_file_actions_addopen(
            &actions, STDIN_FILENO, input_path, O_RDONLY, 0) != 0 ||
        posix_spawn_file_actions_addopen(
            &actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return 0;
    }
    start = now_ms();
    error = posix_spawnp(&child, command[0], &actions, NULL, command, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (error != 0) {
        errno = error;
        perror("posix_spawnp");
        return 0;
    }
    if (wait4(child, &status, 0, &usage) != child) return 0;
    result->milliseconds = now_ms() - start;
#if defined(__APPLE__)
    result->max_rss_bytes = (uint64_t)usage.ru_maxrss;
#else
    result->max_rss_bytes = (uint64_t)usage.ru_maxrss * 1024u;
#endif
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

int main(int argc, char **argv) {
    sample *samples;
    double sum = 0.0;
    uint64_t max_rss = 0;
    uint64_t rss_sum = 0;
    long runs;
    long i;

    if (argc < 4) {
        fprintf(
            stderr,
            "usage: bench-process-startup runs input command [args ...]\n");
        return 2;
    }
    runs = strtol(argv[1], NULL, 10);
    if (runs < 1 || runs > 10000) return 2;
    samples = malloc((size_t)runs * sizeof(*samples));
    if (!samples) return 3;

    for (i = 0; i < 5; ++i) {
        sample warmup;
        if (!run_once(argv[2], &argv[3], &warmup)) return 4;
    }
    for (i = 0; i < runs; ++i) {
        if (!run_once(argv[2], &argv[3], &samples[i])) return 5;
        sum += samples[i].milliseconds;
        rss_sum += samples[i].max_rss_bytes;
        if (samples[i].max_rss_bytes > max_rss) {
            max_rss = samples[i].max_rss_bytes;
        }
    }
    qsort(samples, (size_t)runs, sizeof(*samples), compare_time);
    printf(
        "{\"command\":\"%s\",\"samples\":%ld,"
        "\"mean_ms\":%.6f,\"min_ms\":%.6f,\"p50_ms\":%.6f,"
        "\"p95_ms\":%.6f,\"max_ms\":%.6f,"
        "\"mean_max_rss_bytes\":%llu,\"max_rss_bytes\":%llu}\n",
        argv[3],
        runs,
        sum / (double)runs,
        samples[0].milliseconds,
        samples[runs / 2].milliseconds,
        samples[(runs * 95) / 100].milliseconds,
        samples[runs - 1].milliseconds,
        (unsigned long long)(rss_sum / (uint64_t)runs),
        (unsigned long long)max_rss);
    free(samples);
    return 0;
}
