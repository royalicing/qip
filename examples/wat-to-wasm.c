// wat-to-wasm.c
// WebAssembly Text to Binary converter
// Supports only stack-based instructions (no memory, no locals, no calls)

#include <stdint.h>

// Static memory buffers
static char input_buffer[65536];   // 64KB
static char output_buffer[65536];  // 64KB
static char code_buffer[32768];    // 32KB for code instructions

// Export memory pointer functions
__attribute__((export_name("input_ptr")))
uint32_t input_ptr() {
    return (uint32_t)(uintptr_t)input_buffer;
}

__attribute__((export_name("input_utf8_cap")))
uint32_t input_utf8_cap() {
    return sizeof(input_buffer);
}

__attribute__((export_name("output_ptr")))
uint32_t output_ptr() {
    return (uint32_t)(uintptr_t)output_buffer;
}

__attribute__((export_name("output_bytes_cap")))
uint32_t output_bytes_cap() {
    return sizeof(output_buffer);
}

// WASM opcodes for stack-only instructions
#define OP_UNREACHABLE 0x00
#define OP_NOP         0x01
#define OP_BLOCK       0x02
#define OP_LOOP        0x03
#define OP_BR          0x0C
#define OP_BR_IF       0x0D
#define OP_RETURN      0x0F
#define OP_END         0x0B
#define OP_DROP        0x1A
#define OP_SELECT      0x1B
#define OP_I32_CONST   0x41
#define OP_I32_EQZ     0x45
#define OP_I32_EQ      0x46
#define OP_I32_NE      0x47
#define OP_I32_LT_S    0x48
#define OP_I32_LT_U    0x49
#define OP_I32_GT_S    0x4A
#define OP_I32_GT_U    0x4B
#define OP_I32_LE_S    0x4C
#define OP_I32_LE_U    0x4D
#define OP_I32_GE_S    0x4E
#define OP_I32_GE_U    0x4F
#define OP_I32_CLZ     0x67
#define OP_I32_CTZ     0x68
#define OP_I32_POPCNT  0x69
#define OP_I32_ADD     0x6A
#define OP_I32_SUB     0x6B
#define OP_I32_MUL     0x6C
#define OP_I32_DIV_S   0x6D
#define OP_I32_DIV_U   0x6E
#define OP_I32_REM_S   0x6F
#define OP_I32_REM_U   0x70
#define OP_I32_AND     0x71
#define OP_I32_OR      0x72
#define OP_I32_XOR     0x73
#define OP_I32_SHL     0x74
#define OP_I32_SHR_S   0x75
#define OP_I32_SHR_U   0x76
#define OP_I32_ROTL    0x77
#define OP_I32_ROTR    0x78

typedef struct {
    const char* input;
    uint32_t size;
    uint32_t pos;
} Parser;

typedef struct {
    char* output;
    uint32_t pos;
} Encoder;

// String comparison
static int str_eq(const char* a, const char* b, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        if (a[i] != b[i]) return 0;
    }
    return 1;
}

static void skip_whitespace(Parser* p) {
    while (p->pos < p->size) {
        char c = p->input[p->pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            p->pos++;
        } else if (c == ';' && p->pos + 1 < p->size && p->input[p->pos + 1] == ';') {
            // Skip line comment
            p->pos += 2;
            while (p->pos < p->size && p->input[p->pos] != '\n') {
                p->pos++;
            }
        } else if (p->pos + 1 < p->size && c == '(' && p->input[p->pos + 1] == ';') {
            // Skip block comment
            p->pos += 2;
            while (p->pos + 1 < p->size) {
                if (p->input[p->pos] == ';' && p->input[p->pos + 1] == ')') {
                    p->pos += 2;
                    break;
                }
                p->pos++;
            }
        } else {
            break;
        }
    }
}

static char peek(Parser* p) {
    skip_whitespace(p);
    if (p->pos >= p->size) return 0;
    return p->input[p->pos];
}

static int expect(Parser* p, char expected) {
    skip_whitespace(p);
    if (p->pos >= p->size || p->input[p->pos] != expected) {
        return 0;
    }
    p->pos++;
    return 1;
}

static uint32_t read_ident(Parser* p, const char** out) {
    skip_whitespace(p);
    const char* start = &p->input[p->pos];
    uint32_t len = 0;
    
    while (p->pos < p->size) {
        char c = p->input[p->pos];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-') {
            p->pos++;
            len++;
        } else {
            break;
        }
    }
    
    *out = start;
    return len;
}

static int parse_int(Parser* p, int64_t* value) {
    skip_whitespace(p);
    uint32_t start = p->pos;
    int negative = 0;
    
    if (p->pos < p->size && p->input[p->pos] == '-') {
        negative = 1;
        p->pos++;
    }
    
    int64_t val = 0;
    int has_digit = 0;
    
    while (p->pos < p->size) {
        char c = p->input[p->pos];
        if (c >= '0' && c <= '9') {
            val = val * 10 + (c - '0');
            p->pos++;
            has_digit = 1;
        } else {
            break;
        }
    }
    
    if (!has_digit) {
        p->pos = start;
        return 0;
    }
    
    *value = negative ? -val : val;
    return 1;
}

static void write_byte(Encoder* e, uint8_t byte) {
    if (e->pos < 65536) {
        e->output[e->pos++] = byte;
    }
}

static void write_bytes(Encoder* e, const uint8_t* bytes, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        write_byte(e, bytes[i]);
    }
}

static void write_leb128(Encoder* e, int64_t value) {
    int more = 1;
    while (more) {
        uint8_t byte = value & 0x7F;
        value >>= 7;
        
        if ((value == 0 && (byte & 0x40) == 0) || (value == -1 && (byte & 0x40) != 0)) {
            more = 0;
        } else {
            byte |= 0x80;
        }
        
        write_byte(e, byte);
    }
}

static void write_uleb128(Encoder* e, uint32_t value) {
    int more = 1;
    while (more) {
        uint8_t byte = value & 0x7F;
        value >>= 7;
        
        if (value != 0) {
            byte |= 0x80;
        } else {
            more = 0;
        }
        
        write_byte(e, byte);
    }
}

static int parse_instruction(Parser* p, Encoder* e) {
    if (!expect(p, '(')) return 0;
    
    const char* ident;
    uint32_t len = read_ident(p, &ident);
    
    if (len == 0) return 0;
    
    // Match instruction names to opcodes
    if (len == 3 && str_eq(ident, "nop", 3)) {
        write_byte(e, OP_NOP);
    } else if (len == 11 && str_eq(ident, "unreachable", 11)) {
        write_byte(e, OP_UNREACHABLE);
    } else if (len == 4 && str_eq(ident, "drop", 4)) {
        write_byte(e, OP_DROP);
    } else if (len == 6 && str_eq(ident, "select", 6)) {
        write_byte(e, OP_SELECT);
    } else if (len == 6 && str_eq(ident, "return", 6)) {
        write_byte(e, OP_RETURN);
    } else if (len == 9 && str_eq(ident, "i32.const", 9)) {
        write_byte(e, OP_I32_CONST);
        int64_t val;
        if (!parse_int(p, &val)) return 0;
        write_leb128(e, val);
    } else if (len == 7 && str_eq(ident, "i32.eqz", 7)) {
        write_byte(e, OP_I32_EQZ);
    } else if (len == 6 && str_eq(ident, "i32.eq", 6)) {
        write_byte(e, OP_I32_EQ);
    } else if (len == 6 && str_eq(ident, "i32.ne", 6)) {
        write_byte(e, OP_I32_NE);
    } else if (len == 8 && str_eq(ident, "i32.lt_s", 8)) {
        write_byte(e, OP_I32_LT_S);
    } else if (len == 8 && str_eq(ident, "i32.lt_u", 8)) {
        write_byte(e, OP_I32_LT_U);
    } else if (len == 8 && str_eq(ident, "i32.gt_s", 8)) {
        write_byte(e, OP_I32_GT_S);
    } else if (len == 8 && str_eq(ident, "i32.gt_u", 8)) {
        write_byte(e, OP_I32_GT_U);
    } else if (len == 8 && str_eq(ident, "i32.le_s", 8)) {
        write_byte(e, OP_I32_LE_S);
    } else if (len == 8 && str_eq(ident, "i32.le_u", 8)) {
        write_byte(e, OP_I32_LE_U);
    } else if (len == 8 && str_eq(ident, "i32.ge_s", 8)) {
        write_byte(e, OP_I32_GE_S);
    } else if (len == 8 && str_eq(ident, "i32.ge_u", 8)) {
        write_byte(e, OP_I32_GE_U);
    } else if (len == 7 && str_eq(ident, "i32.clz", 7)) {
        write_byte(e, OP_I32_CLZ);
    } else if (len == 7 && str_eq(ident, "i32.ctz", 7)) {
        write_byte(e, OP_I32_CTZ);
    } else if (len == 10 && str_eq(ident, "i32.popcnt", 10)) {
        write_byte(e, OP_I32_POPCNT);
    } else if (len == 7 && str_eq(ident, "i32.add", 7)) {
        write_byte(e, OP_I32_ADD);
    } else if (len == 7 && str_eq(ident, "i32.sub", 7)) {
        write_byte(e, OP_I32_SUB);
    } else if (len == 7 && str_eq(ident, "i32.mul", 7)) {
        write_byte(e, OP_I32_MUL);
    } else if (len == 9 && str_eq(ident, "i32.div_s", 9)) {
        write_byte(e, OP_I32_DIV_S);
    } else if (len == 9 && str_eq(ident, "i32.div_u", 9)) {
        write_byte(e, OP_I32_DIV_U);
    } else if (len == 9 && str_eq(ident, "i32.rem_s", 9)) {
        write_byte(e, OP_I32_REM_S);
    } else if (len == 9 && str_eq(ident, "i32.rem_u", 9)) {
        write_byte(e, OP_I32_REM_U);
    } else if (len == 7 && str_eq(ident, "i32.and", 7)) {
        write_byte(e, OP_I32_AND);
    } else if (len == 6 && str_eq(ident, "i32.or", 6)) {
        write_byte(e, OP_I32_OR);
    } else if (len == 7 && str_eq(ident, "i32.xor", 7)) {
        write_byte(e, OP_I32_XOR);
    } else if (len == 7 && str_eq(ident, "i32.shl", 7)) {
        write_byte(e, OP_I32_SHL);
    } else if (len == 9 && str_eq(ident, "i32.shr_s", 9)) {
        write_byte(e, OP_I32_SHR_S);
    } else if (len == 9 && str_eq(ident, "i32.shr_u", 9)) {
        write_byte(e, OP_I32_SHR_U);
    } else if (len == 8 && str_eq(ident, "i32.rotl", 8)) {
        write_byte(e, OP_I32_ROTL);
    } else if (len == 8 && str_eq(ident, "i32.rotr", 8)) {
        write_byte(e, OP_I32_ROTR);
    } else {
        // Unknown instruction
        return 0;
    }
    
    if (!expect(p, ')')) return 0;
    return 1;
}

static void parse_instructions(Parser* p, Encoder* e) {
    while (peek(p) != 0 && peek(p) != ')') {
        if (!parse_instruction(p, e)) break;
    }
}

__attribute__((export_name("run")))
uint32_t run(uint32_t input_size) {
    if (input_size > sizeof(input_buffer)) {
        input_size = sizeof(input_buffer);
    }
    
    // Parse instructions from input into code_buffer
    Parser parser = { input_buffer, input_size, 0 };
    Encoder code_encoder = { code_buffer, 0 };
    parse_instructions(&parser, &code_encoder);
    
    // Build the actual WASM module into output_buffer
    Encoder encoder = { output_buffer, 0 };
    
    // WASM magic number
    write_bytes(&encoder, (const uint8_t[]){0x00, 0x61, 0x73, 0x6D}, 4);
    // WASM version
    write_bytes(&encoder, (const uint8_t[]){0x01, 0x00, 0x00, 0x00}, 4);
    
    // Type section (id = 1)
    write_byte(&encoder, 0x01);
    write_byte(&encoder, 0x05); // section size
    write_uleb128(&encoder, 1); // 1 type
    write_byte(&encoder, 0x60); // func type
    write_uleb128(&encoder, 0); // 0 params
    write_uleb128(&encoder, 1); // 1 result
    write_byte(&encoder, 0x7F); // i32
    
    // Function section (id = 3)
    write_byte(&encoder, 0x03);
    write_byte(&encoder, 0x02); // section size
    write_uleb128(&encoder, 1); // 1 function
    write_uleb128(&encoder, 0); // type index 0
    
    // Export section (id = 7)
    write_byte(&encoder, 0x07);
    write_byte(&encoder, 0x08); // section size: 1(count) + 1(name_len) + 4(name) + 1(kind) + 1(index) = 8
    write_uleb128(&encoder, 1); // 1 export
    write_uleb128(&encoder, 4); // name length
    write_bytes(&encoder, (const uint8_t*)"calc", 4); // export name
    write_byte(&encoder, 0x00); // export kind (func)
    write_uleb128(&encoder, 0); // function index
    
    // Code section (id = 10)
    write_byte(&encoder, 0x0A);
    
    // Function body = locals_count (LEB128) + code + end_opcode
    // func_size = size of locals_count + code_encoder.pos + 1 (end opcode)
    uint32_t func_size = 1 + code_encoder.pos + 1; // 1 byte for locals count (0) + instructions + end
    
    // Calculate actual LEB128 sizes
    // We need to encode temporarily to figure out sizes
    // For small values (< 128), LEB128 is 1 byte
    // Since we only have 1 function and func_size is typically small, we can use 1 byte for each
    // But to be safe, let's calculate the size properly
    uint32_t func_count_size = 1; // func_count=1 always fits in 1 byte
    uint32_t func_size_bytes = (func_size < 128) ? 1 : ((func_size < 16384) ? 2 : 3);
    uint32_t section_size = func_count_size + func_size_bytes + func_size;
    write_uleb128(&encoder, section_size);
    
    write_uleb128(&encoder, 1); // 1 function
    write_uleb128(&encoder, func_size); // function size
    write_uleb128(&encoder, 0); // 0 locals
    
    // Copy the encoded instructions
    write_bytes(&encoder, (const uint8_t*)code_encoder.output, code_encoder.pos);
    
    // End opcode
    write_byte(&encoder, OP_END);
    
    return encoder.pos;
}
