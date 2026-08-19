#include <stdint.h>
#include <stdlib.h>

#define QIP_WASM_GENERIC_API
#define QIP_WASM_IMPLEMENTATION
#include QIP_WASM_GENERATED_HEADER

static int expect(
    qip_wasm_instance *instance,
    qip_render_workspace *workspace,
    uint8_t input,
    qip_wasm_status expected) {
    uint32_t output_offset = 0;
    uint32_t output_size = 0;
    if (expected != QIP_WASM_STALE_INSTANCE) {
        workspace->memory[QIP_WASM_INPUT_OFFSET] = input;
    }
    qip_wasm_status status = qip_wasm_render(
        instance, 1, &output_offset, &output_size);
    if (status != expected) return 0;
    if (status == QIP_WASM_OK &&
        (output_size != 2 ||
         workspace->memory[output_offset] != 'o' ||
         workspace->memory[output_offset + 1] != 'k')) return 0;
    return 1;
}

int main(void) {
    qip_wasm_instance *instance = malloc(sizeof(*instance));
    size_t allocation_size =
        qip_render_workspace_allocation_size((size_t)QIP_WASM_MEMORY_SIZE);
    uint8_t *memory = calloc(1, allocation_size);
    qip_render_workspace workspace = {
        memory,
        (size_t)QIP_WASM_MEMORY_SIZE,
    };
    qip_render_workspace too_small = {
        memory,
        (size_t)QIP_WASM_MEMORY_SIZE - 1,
    };
    uint32_t offset;
    if (!instance || !memory) return 2;
    if (qip_wasm_init(instance, &workspace, 1) !=
        QIP_WASM_OK) {
        free(memory);
        free(instance);
        return 2;
    }

    if (!expect(instance, &workspace, 'd', QIP_WASM_TRAP_DIV_ZERO) ||
        !expect(instance, &workspace, 'v', QIP_WASM_OK) ||
        !expect(instance, &workspace, 'c', QIP_WASM_TRAP_INVALID_CONVERSION) ||
        !expect(instance, &workspace, 'v', QIP_WASM_OK) ||
        !expect(instance, &workspace, 'n', QIP_WASM_TRAP_INDIRECT_NULL) ||
        !expect(instance, &workspace, 'v', QIP_WASM_OK) ||
        !expect(instance, &workspace, 'o', QIP_WASM_TRAP_TABLE_OOB) ||
        !expect(instance, &workspace, 'v', QIP_WASM_OK) ||
        !expect(instance, &workspace, 't', QIP_WASM_TRAP_INDIRECT_TYPE) ||
        !expect(instance, &workspace, 'v', QIP_WASM_OK)) {
        free(memory);
        free(instance);
        return 1;
    }
    if (qip_wasm_init(instance, &too_small, 1) !=
            QIP_WASM_MEMORY_TOO_SMALL ||
        qip_wasm_init(NULL, &workspace, 1) !=
            QIP_WASM_INVALID_ARGUMENT) {
        free(memory);
        free(instance);
        return 3;
    }
    if (qip_wasm_dirty_page_count(instance) != 1) {
        free(memory);
        free(instance);
        return 4;
    }
    if (qip_render_workspace_clear(&workspace) != 1) {
        free(memory);
        free(instance);
        return 5;
    }
    if (qip_wasm_dirty_page_count(instance) != 0) {
        free(memory);
        free(instance);
        return 6;
    }
    if (!expect(instance, &workspace, 'v', QIP_WASM_STALE_INSTANCE)) {
        free(memory);
        free(instance);
        return 7;
    }
    for (offset = 0; offset < QIP_WASM_MEMORY_SIZE; ++offset) {
        if (memory[offset] != 0) {
            free(memory);
            free(instance);
            return 8;
        }
    }
    workspace.memory[QIP_WASM_INPUT_OFFSET] = 'v';
    if (qip_wasm_init(instance, &workspace, 1) !=
            QIP_WASM_OK ||
        !expect(instance, &workspace, 'v', QIP_WASM_OK)) {
        free(memory);
        free(instance);
        return 9;
    }
    qip_render_workspace_clear(&workspace);
    free(memory);
    free(instance);
    return 0;
}
