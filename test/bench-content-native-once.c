#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define INITIAL_INPUT_CAPACITY (64u * 1024u)
#define MAX_INPUT_CAPACITY (512u * 1024u * 1024u)

extern size_t qip_native_output_capacity(void);
extern uint32_t qip_native_render(
    const uint8_t *input,
    size_t input_size,
    uint8_t *output,
    size_t output_capacity);

int main(void) {
    size_t input_capacity = INITIAL_INPUT_CAPACITY;
    size_t input_size = 0;
    size_t output_capacity = qip_native_output_capacity();
    uint8_t *input = malloc(input_capacity);
    uint8_t *output = malloc(output_capacity);
    uint32_t output_size;

    if (!input || !output) return 2;
    for (;;) {
        size_t read_size =
            fread(input + input_size, 1, input_capacity - input_size, stdin);
        input_size += read_size;
        if (ferror(stdin)) return 3;
        if (feof(stdin)) break;
        if (input_capacity == MAX_INPUT_CAPACITY) return 3;
        input_capacity *= 2;
        if (input_capacity > MAX_INPUT_CAPACITY) input_capacity = MAX_INPUT_CAPACITY;
        input = realloc(input, input_capacity);
        if (!input) return 2;
    }
    output_size = qip_native_render(
        input,
        input_size,
        output,
        output_capacity);
    if (fwrite(output, 1, output_size, stdout) != output_size) return 4;
    free(output);
    free(input);
    return 0;
}
