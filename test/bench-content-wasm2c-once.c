#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include WASM2C_GENERATED_HEADER

int main(void) {
    w2c_qipbench instance;
    wasm_rt_memory_t *memory;
    uint8_t *input;
    uint32_t input_ptr;
    uint32_t output_ptr;
    uint32_t output_size;
    size_t input_size;

    input = malloc(16u * 1024u * 1024u);
    if (!input) return 2;
    input_size = fread(input, 1, 16u * 1024u * 1024u, stdin);
    if (ferror(stdin) ||
        (!feof(stdin) && input_size == 16u * 1024u * 1024u)) return 3;
    wasm_rt_init();
    wasm2c_qipbench_instantiate(&instance);
    memory = w2c_qipbench_memory(&instance);
    input_ptr = w2c_qipbench_input_ptr(&instance);
    memcpy(memory->data + input_ptr, input, input_size);
    output_size = w2c_qipbench_render(&instance, (uint32_t)input_size);
    output_ptr = w2c_qipbench_output_ptr(&instance);
    if (fwrite(memory->data + output_ptr, 1, output_size, stdout) !=
        output_size) return 4;
    wasm2c_qipbench_free(&instance);
    wasm_rt_free();
    free(input);
    return 0;
}
