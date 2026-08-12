#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define QIP_WASM_IMPLEMENTATION
#include QIP_WASM_GENERATED_HEADER_A
#include QIP_WASM_GENERATED_HEADER_B

int main(void) {
    QIP_A_INSTANCE a;
    QIP_B_INSTANCE b;
    uint8_t input[] = "shared arena";
    uint8_t *memory;
    qip_render_workspace workspace;
    uint32_t output_offset;
    uint32_t output_size;
    size_t memory_size =
        QIP_A_MEMORY_SIZE > QIP_B_MEMORY_SIZE
            ? (size_t)QIP_A_MEMORY_SIZE
            : (size_t)QIP_B_MEMORY_SIZE;
    size_t allocation_size =
        qip_render_workspace_allocation_size(memory_size);

    memory = calloc(1, allocation_size);
    if (!memory) return 1;
    workspace = (qip_render_workspace){memory, memory_size};
    memcpy(
        workspace.memory + QIP_A_INPUT_OFFSET,
        input,
        sizeof(input) - 1);
    if (QIP_A_INIT(&a, &workspace, (uint32_t)(sizeof(input) - 1)) != 0 ||
        QIP_A_RENDER(
            &a,
            (uint32_t)(sizeof(input) - 1),
            &output_offset,
            &output_size) != 0) {
        free(memory);
        return 2;
    }
    if (output_size > QIP_B_INPUT_CAPACITY) return 3;
    memmove(
        workspace.memory + QIP_B_INPUT_OFFSET,
        workspace.memory + output_offset,
        output_size);
    if (QIP_B_INIT(&b, &workspace, output_size) != 0 ||
        QIP_B_RENDER(
            &b,
            output_size,
            &output_offset,
            &output_size) != 0 ||
        QIP_A_RENDER(
            &a,
            (uint32_t)(sizeof(input) - 1),
            &output_offset,
            &output_size) != QIP_A_STALE_INSTANCE) {
        free(memory);
        return 4;
    }
    qip_render_workspace_clear(&workspace);
    free(memory);
    return 0;
}
