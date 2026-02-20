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

static unsigned char ascii_lower(unsigned char c) {
    if (c >= 'A' && c <= 'Z') {
        return (unsigned char)(c + ('a' - 'A'));
    }
    return c;
}

static int starts_with_https(const unsigned char *s, uint32_t i, uint32_t n) {
    return i + 7 < n &&
           s[i] == 'h' &&
           s[i + 1] == 't' &&
           s[i + 2] == 't' &&
           s[i + 3] == 'p' &&
           s[i + 4] == 's' &&
           s[i + 5] == ':' &&
           s[i + 6] == '/' &&
           s[i + 7] == '/';
}

static int equals_ci(const unsigned char *s, uint32_t len, const char *lit) {
    uint32_t i = 0;
    while (lit[i] != '\0') {
        if (i >= len) return 0;
        if (ascii_lower(s[i]) != (unsigned char)lit[i]) return 0;
        i++;
    }
    return i == len;
}

static int is_self_closing_tag(const unsigned char *s, uint32_t tag_start, uint32_t tag_end) {
    if (tag_end <= tag_start + 1) return 0;
    uint32_t p = tag_end;
    while (p > tag_start + 1 && is_ws(s[p - 1])) p--;
    if (p <= tag_start + 1) return 0;
    return s[p - 1] == '/';
}

static void update_html_context(const unsigned char *s, uint32_t tag_start, uint32_t tag_end, int *raw_text_mode, int *anchor_depth) {
    uint32_t p = tag_start + 1;
    while (p < tag_end && is_ws(s[p])) p++;
    if (p >= tag_end) return;
    if (s[p] == '!' || s[p] == '?') return;

    int closing = 0;
    if (s[p] == '/') {
        closing = 1;
        p++;
    }
    while (p < tag_end && is_ws(s[p])) p++;
    if (p >= tag_end) return;

    uint32_t name_start = p;
    while (p < tag_end) {
        unsigned char c = s[p];
        int alpha_num = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        if (!alpha_num) break;
        p++;
    }
    uint32_t name_len = p - name_start;
    if (name_len == 0) return;

    if (equals_ci(s + name_start, name_len, "script")) {
        if (closing && *raw_text_mode == 1) *raw_text_mode = 0;
        if (!closing) *raw_text_mode = 1;
        return;
    }
    if (equals_ci(s + name_start, name_len, "style")) {
        if (closing && *raw_text_mode == 2) *raw_text_mode = 0;
        if (!closing) *raw_text_mode = 2;
        return;
    }

    if (equals_ci(s + name_start, name_len, "a")) {
        if (closing) {
            if (*anchor_depth > 0) *anchor_depth -= 1;
        } else if (!is_self_closing_tag(s, tag_start, tag_end)) {
            *anchor_depth += 1;
        }
    }
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
    uint32_t tag_start = 0;
    int in_tag = 0;
    unsigned char tag_quote = 0;
    int raw_text_mode = 0; /* 0=none, 1=script, 2=style */
    int anchor_depth = 0;

    while (i < input_size) {
        unsigned char c = input_buffer[i];

        if (in_tag) {
            if (!write_slice(&out_idx, &c, 1)) return 0;
            if (tag_quote != 0) {
                if (c == tag_quote) {
                    tag_quote = 0;
                }
            } else {
                if (c == '"' || c == '\'') {
                    tag_quote = c;
                } else if (c == '>') {
                    in_tag = 0;
                    update_html_context(input_buffer, tag_start, i, &raw_text_mode, &anchor_depth);
                }
            }
            i++;
            continue;
        }

        if (c == '<') {
            tag_start = i;
            in_tag = 1;
            tag_quote = 0;
            if (!write_slice(&out_idx, &c, 1)) return 0;
            i++;
            continue;
        }

        if (raw_text_mode == 0 && anchor_depth == 0 && starts_with_https(input_buffer, i, input_size)) {
            uint32_t start = i;
            uint32_t j = i + 8;
            while (j < input_size && !is_url_stop(input_buffer[j])) {
                j++;
            }
            uint32_t url_len = j - start;
            if (!write_slice(&out_idx, (const unsigned char *)"<a href=\"", 9)) return 0;
            if (!write_escaped_attr(&out_idx, input_buffer + start, url_len)) return 0;
            if (!write_slice(&out_idx, (const unsigned char *)"\">", 2)) return 0;
            if (!write_slice(&out_idx, input_buffer + start, url_len)) return 0;
            if (!write_slice(&out_idx, (const unsigned char *)"</a>", 4)) return 0;
            i = j;
            continue;
        }
        if (!write_slice(&out_idx, &c, 1)) return 0;
        i++;
    }

    return out_idx;
}
