#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define QIP_WASM_GENERIC_API
#define QIP_WASM_IMPLEMENTATION
#include QIP_WASM_GENERATED_HEADER

int main(void) {
    qip_wasm_instance instance;
    qip_render_workspace workspace;
    uint8_t *allocation;
    uint32_t output_offset;
    uint32_t output_size;
    size_t allocation_size;
    size_t input_size;

    allocation_size =
        qip_render_workspace_allocation_size((size_t)QIP_WASM_MEMORY_SIZE);
    allocation = calloc(1, allocation_size);
    if (!allocation) return 2;
    workspace = (qip_render_workspace){
        allocation,
        (size_t)QIP_WASM_MEMORY_SIZE,
    };
    input_size = fread(
        workspace.memory + QIP_WASM_INPUT_OFFSET,
        1,
        QIP_WASM_INPUT_CAPACITY,
        stdin);
    if (ferror(stdin) ||
        (!feof(stdin) && input_size == QIP_WASM_INPUT_CAPACITY)) return 3;
    if (qip_wasm_init(&instance, &workspace, (uint32_t)input_size) !=
        QIP_WASM_OK) return 4;
    if (qip_wasm_render(
            &instance,
            (uint32_t)input_size,
            &output_offset,
            &output_size) != QIP_WASM_OK) return 5;
    if (fwrite(workspace.memory + output_offset, 1, output_size, stdout) !=
        output_size) return 6;
    free(allocation);
    return 0;
}
