#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define QIP_WASM_GENERIC_API
#define QIP_WASM_IMPLEMENTATION
#include QIP_WASM_GENERATED_HEADER

int main(void) {
    qip_wasm_instance *instance;
    qip_wasm_instance *second_instance;
    qip_wasm_status status;
    uint8_t *input;
    uint8_t *first_output;
    uint8_t *memory;
    uint8_t *second_memory;
    qip_render_workspace workspace;
    qip_render_workspace second_workspace;
    uint32_t output_offset = 0;
    uint32_t first_output_offset = 0;
    uint32_t output_size = 0;
    uint32_t first_output_size = 0;
    size_t input_size;

    instance = malloc(sizeof(*instance));
    second_instance = malloc(sizeof(*second_instance));
    input = malloc(16 * 1024 * 1024);
    first_output = malloc(16 * 1024 * 1024);
    memory = calloc(1, qip_render_workspace_allocation_size((size_t)QIP_WASM_MEMORY_SIZE));
    second_memory = calloc(1, qip_render_workspace_allocation_size((size_t)QIP_WASM_MEMORY_SIZE));
    if (!instance || !second_instance || !input || !first_output ||
        !memory || !second_memory) return 3;
    workspace = (qip_render_workspace){memory, (size_t)QIP_WASM_MEMORY_SIZE};
    second_workspace = (qip_render_workspace){second_memory, (size_t)QIP_WASM_MEMORY_SIZE};
    input_size = fread(input, 1, 16 * 1024 * 1024, stdin);
    if (ferror(stdin) || (!feof(stdin) && input_size == 16 * 1024 * 1024)) return 6;

    memcpy(workspace.memory + QIP_WASM_INPUT_OFFSET, input, input_size);
    if (qip_wasm_init(instance, &workspace, (uint32_t)input_size) !=
        QIP_WASM_OK) return 8;
    status = qip_wasm_render(
        instance,
        (uint32_t)input_size,
        &first_output_offset,
        &first_output_size);
    if (status != QIP_WASM_OK) return 4;
    memcpy(first_output, workspace.memory + first_output_offset, first_output_size);

    memcpy(second_workspace.memory + QIP_WASM_INPUT_OFFSET, input, input_size);
    if (qip_wasm_init(second_instance, &second_workspace, (uint32_t)input_size) !=
        QIP_WASM_OK) return 8;
    status = qip_wasm_render(
        second_instance,
        (uint32_t)input_size,
        &output_offset,
        &output_size);
    if (status != QIP_WASM_OK) {
        free(first_output);
        return 4;
    }
    if (first_output_size != output_size ||
        memcmp(first_output, second_workspace.memory + output_offset, output_size) != 0) {
        free(first_output);
        return 7;
    }
    free(first_output);
    if (fwrite(second_workspace.memory + output_offset, 1, output_size, stdout) !=
        output_size) return 5;
    qip_render_workspace_clear(&workspace);
    qip_render_workspace_clear(&second_workspace);
    free(memory);
    free(second_memory);
    free(instance);
    free(second_instance);
    free(input);
    return 0;
}
