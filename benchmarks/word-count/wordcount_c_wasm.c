#include <stdint.h>

#define INPUT_CAP (8u * 1024u * 1024u)
#define OUTPUT_CAP (2u * 1024u * 1024u)
#define TOKEN_CAP 2048u
#define TABLE_CAP (1u << 17) /* 131072 */
#define ARENA_CAP (8u * 1024u * 1024u)

typedef struct {
    uint32_t off;
    uint32_t len;
    uint32_t count;
    uint64_t hash;
    uint8_t used;
} Entry;

static unsigned char input_buf[INPUT_CAP];
static unsigned char output_buf[OUTPUT_CAP];
static unsigned char token_buf[TOKEN_CAP];
static unsigned char word_arena[ARENA_CAP];
static Entry table[TABLE_CAP];

static uint32_t arena_used = 0;
static uint32_t out_pos = 0;
static uint32_t unique_count = 0;
static uint32_t total_count = 0;

__attribute__((export_name("input_ptr")))
uint32_t input_ptr(void) {
    return (uint32_t)(uintptr_t)input_buf;
}

__attribute__((export_name("input_bytes_cap")))
uint32_t input_bytes_cap(void) {
    return INPUT_CAP;
}

__attribute__((export_name("output_ptr")))
uint32_t output_ptr(void) {
    return (uint32_t)(uintptr_t)output_buf;
}

__attribute__((export_name("output_bytes_cap")))
uint32_t output_bytes_cap(void) {
    return OUTPUT_CAP;
}

static void trap(void) {
    __builtin_trap();
}

static int is_ascii_letter(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static unsigned char to_ascii_lower(unsigned char c) {
    if (c >= 'A' && c <= 'Z') {
        return (unsigned char)(c + 32);
    }
    return c;
}

static uint64_t fnv1a(const unsigned char *s, uint32_t len) {
    uint64_t h = 1469598103934665603ULL;
    uint32_t i;
    for (i = 0; i < len; i++) {
        h ^= (uint64_t)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static int bytes_equal(const unsigned char *a, const unsigned char *b, uint32_t len) {
    uint32_t i;
    for (i = 0; i < len; i++) {
        if (a[i] != b[i]) {
            return 0;
        }
    }
    return 1;
}

static void write_byte(unsigned char b) {
    if (out_pos >= OUTPUT_CAP) {
        trap();
    }
    output_buf[out_pos++] = b;
}

static void write_bytes(const unsigned char *s, uint32_t len) {
    uint32_t i;
    for (i = 0; i < len; i++) {
        write_byte(s[i]);
    }
}

static void write_u32(uint32_t v) {
    unsigned char tmp[16];
    uint32_t n = 0;
    if (v == 0) {
        write_byte((unsigned char)'0');
        return;
    }
    while (v > 0) {
        tmp[n++] = (unsigned char)('0' + (v % 10u));
        v /= 10u;
    }
    while (n > 0) {
        n--;
        write_byte(tmp[n]);
    }
}

static int word_cmp(const Entry *a, const Entry *b) {
    uint32_t i = 0;
    uint32_t min_len = a->len < b->len ? a->len : b->len;
    while (i < min_len) {
        unsigned char ca = word_arena[a->off + i];
        unsigned char cb = word_arena[b->off + i];
        if (ca < cb) return -1;
        if (ca > cb) return 1;
        i++;
    }
    if (a->len < b->len) return -1;
    if (a->len > b->len) return 1;
    return 0;
}

static int entry_better(const Entry *a, const Entry *b) {
    if (a->count != b->count) {
        return a->count > b->count;
    }
    return word_cmp(a, b) < 0;
}

static Entry *lookup_or_insert(const unsigned char *word, uint32_t len) {
    uint64_t hash = fnv1a(word, len);
    uint32_t mask = TABLE_CAP - 1u;
    uint32_t idx = (uint32_t)hash & mask;
    uint32_t start = idx;

    while (1) {
        Entry *e = &table[idx];
        if (!e->used) {
            if (arena_used + len > ARENA_CAP) {
                trap();
            }
            e->off = arena_used;
            e->len = len;
            e->count = 0;
            e->hash = hash;
            e->used = 1;
            {
                uint32_t i;
                for (i = 0; i < len; i++) {
                    word_arena[arena_used + i] = word[i];
                }
            }
            arena_used += len;
            unique_count++;
            return e;
        }

        if (e->hash == hash && e->len == len &&
            bytes_equal(&word_arena[e->off], word, len)) {
            return e;
        }

        idx = (idx + 1u) & mask;
        if (idx == start) {
            trap();
        }
    }
}

static void consume_token(uint32_t token_len) {
    Entry *e;
    if (token_len == 0) return;
    e = lookup_or_insert(token_buf, token_len);
    e->count++;
    total_count++;
}

static void clear_state(void) {
    uint32_t i;
    for (i = 0; i < TABLE_CAP; i++) {
        table[i].used = 0;
        table[i].count = 0;
        table[i].len = 0;
        table[i].off = 0;
        table[i].hash = 0;
    }
    arena_used = 0;
    out_pos = 0;
    unique_count = 0;
    total_count = 0;
}

__attribute__((export_name("render")))
uint32_t render(uint32_t input_size) {
    uint32_t i;
    uint32_t token_len = 0;
    Entry *top[10];
    uint32_t top_n = 0;

    if (input_size > INPUT_CAP) {
        trap();
    }

    clear_state();

    for (i = 0; i < input_size; i++) {
        unsigned char c = input_buf[i];
        if (is_ascii_letter(c)) {
            if (token_len >= TOKEN_CAP) {
                trap();
            }
            token_buf[token_len++] = to_ascii_lower(c);
            continue;
        }
        if (token_len > 0) {
            consume_token(token_len);
            token_len = 0;
        }
    }
    if (token_len > 0) {
        consume_token(token_len);
    }

    for (i = 0; i < TABLE_CAP; i++) {
        Entry *e;
        uint32_t j;
        if (!table[i].used) continue;
        e = &table[i];

        if (top_n < 10u) {
            top[top_n++] = e;
        } else if (!entry_better(e, top[top_n - 1u])) {
            continue;
        } else {
            top[top_n - 1u] = e;
        }

        j = top_n;
        while (j > 1u && entry_better(top[j - 1u], top[j - 2u])) {
            Entry *tmp = top[j - 1u];
            top[j - 1u] = top[j - 2u];
            top[j - 2u] = tmp;
            j--;
        }
    }

    for (i = 0; i < top_n; i++) {
        Entry *e = top[i];
        write_u32(e->count);
        write_byte((unsigned char)'\t');
        write_bytes(&word_arena[e->off], e->len);
        write_byte((unsigned char)'\n');
    }
    write_bytes((const unsigned char *)"--\n", 3u);
    write_bytes((const unsigned char *)"total\t", 6u);
    write_u32(total_count);
    write_byte((unsigned char)'\n');
    write_bytes((const unsigned char *)"unique\t", 7u);
    write_u32(unique_count);
    write_byte((unsigned char)'\n');

    return out_pos;
}
