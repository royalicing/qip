#include <stdint.h>
#include <stddef.h>

#define INPUT_CAP (1024 * 1024)
#define OUTPUT_CAP (4 * 1024 * 1024)

static unsigned char input_buffer[INPUT_CAP];
static unsigned char output_buffer[OUTPUT_CAP];

__attribute__((export_name("input_ptr")))
uint32_t input_ptr() {
    return (uint32_t)(uintptr_t)input_buffer;
}

__attribute__((export_name("input_utf8_cap")))
uint32_t input_utf8_cap() {
    return INPUT_CAP;
}

__attribute__((export_name("output_ptr")))
uint32_t output_ptr() {
    return (uint32_t)(uintptr_t)output_buffer;
}

__attribute__((export_name("output_utf8_cap")))
uint32_t output_utf8_cap() {
    return OUTPUT_CAP;
}

static int is_ws(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static int is_url_stop(unsigned char c) {
    return is_ws(c) || c == '<' || c == '>' || c == '"' || c == '\'';
}

static int write_slice(uint32_t *out_idx, const unsigned char *s, uint32_t len) {
    if (*out_idx + len > OUTPUT_CAP) {
        return 0;
    }
    for (uint32_t i = 0; i < len; i++) {
        output_buffer[*out_idx + i] = s[i];
    }
    *out_idx += len;
    return 1;
}

static int write_escaped_text(uint32_t *out_idx, const unsigned char *s, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        unsigned char c = s[i];
        if (c == '&') {
            if (!write_slice(out_idx, (const unsigned char *)"&amp;", 5)) return 0;
        } else if (c == '<') {
            if (!write_slice(out_idx, (const unsigned char *)"&lt;", 4)) return 0;
        } else if (c == '>') {
            if (!write_slice(out_idx, (const unsigned char *)"&gt;", 4)) return 0;
        } else {
            if (!write_slice(out_idx, &c, 1)) return 0;
        }
    }
    return 1;
}

static int write_escaped_attr(uint32_t *out_idx, const unsigned char *s, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        unsigned char c = s[i];
        if (c == '&') {
            if (!write_slice(out_idx, (const unsigned char *)"&amp;", 5)) return 0;
        } else if (c == '<') {
            if (!write_slice(out_idx, (const unsigned char *)"&lt;", 4)) return 0;
        } else if (c == '>') {
            if (!write_slice(out_idx, (const unsigned char *)"&gt;", 4)) return 0;
        } else if (c == '"') {
            if (!write_slice(out_idx, (const unsigned char *)"&quot;", 6)) return 0;
        } else {
            if (!write_slice(out_idx, &c, 1)) return 0;
        }
    }
    return 1;
}

__attribute__((export_name("run")))
uint32_t run(uint32_t input_size) {
    if (input_size > INPUT_CAP) {
        input_size = INPUT_CAP;
    }

    uint32_t out_idx = 0;
    uint32_t i = 0;
    while (i < input_size) {
        if (input_buffer[i] == 'h' && i + 7 < input_size &&
            input_buffer[i + 1] == 't' &&
            input_buffer[i + 2] == 't' &&
            input_buffer[i + 3] == 'p' &&
            input_buffer[i + 4] == 's' &&
            input_buffer[i + 5] == ':' &&
            input_buffer[i + 6] == '/' &&
            input_buffer[i + 7] == '/') {
            uint32_t start = i;
            uint32_t j = i + 8;
            while (j < input_size && !is_url_stop(input_buffer[j])) {
                j++;
            }
            uint32_t url_len = j - start;
            if (!write_slice(&out_idx, (const unsigned char *)"<a href=\"", 9)) return 0;
            if (!write_escaped_attr(&out_idx, input_buffer + start, url_len)) return 0;
            if (!write_slice(&out_idx, (const unsigned char *)"\">", 2)) return 0;
            if (!write_escaped_text(&out_idx, input_buffer + start, url_len)) return 0;
            if (!write_slice(&out_idx, (const unsigned char *)"</a>", 4)) return 0;
            i = j;
            continue;
        }
        if (!write_escaped_text(&out_idx, input_buffer + i, 1)) return 0;
        i++;
    }

    return out_idx;
}
