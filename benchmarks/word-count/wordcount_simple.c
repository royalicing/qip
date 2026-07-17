#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *word;
    size_t count;
} Entry;

typedef struct {
    Entry *items;
    size_t len;
    size_t cap;
} EntryVec;

static void *xmalloc(size_t n) {
    void *p = malloc(n);
    if (!p) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return p;
}

static void *xrealloc(void *p, size_t n) {
    void *q = realloc(p, n);
    if (!q) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return q;
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

static char *dup_slice(const char *s, size_t n) {
    char *out = (char *)xmalloc(n + 1);
    memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

static void vec_push(EntryVec *v, char *word) {
    if (v->len == v->cap) {
        size_t next = v->cap == 0 ? 128 : v->cap * 2;
        v->items = (Entry *)xrealloc(v->items, next * sizeof(Entry));
        v->cap = next;
    }
    v->items[v->len].word = word;
    v->items[v->len].count = 1;
    v->len++;
}

static int cmp_entry_desc_count_asc_word(const void *a, const void *b) {
    const Entry *ea = (const Entry *)a;
    const Entry *eb = (const Entry *)b;
    if (ea->count != eb->count) {
        return (ea->count < eb->count) ? 1 : -1;
    }
    return strcmp(ea->word, eb->word);
}

int main(void) {
    EntryVec entries = {0};
    size_t total_words = 0;

    char *token = NULL;
    size_t token_len = 0;
    size_t token_cap = 0;

    unsigned char buf[1 << 15];
    while (1) {
        size_t nread = fread(buf, 1, sizeof(buf), stdin);
        if (nread == 0) {
            if (ferror(stdin)) {
                fprintf(stderr, "read error\n");
                return 1;
            }
            break;
        }

        for (size_t i = 0; i < nread; i++) {
            unsigned char c = buf[i];
            if (is_ascii_letter(c)) {
                if (token_len + 1 >= token_cap) {
                    size_t next = token_cap == 0 ? 32 : token_cap * 2;
                    token = (char *)xrealloc(token, next);
                    token_cap = next;
                }
                token[token_len++] = (char)to_ascii_lower(c);
                continue;
            }

            if (token_len == 0) {
                continue;
            }

            token[token_len] = '\0';
            int found = 0;
            for (size_t j = 0; j < entries.len; j++) {
                if (strcmp(entries.items[j].word, token) == 0) {
                    entries.items[j].count++;
                    found = 1;
                    break;
                }
            }
            if (!found) {
                vec_push(&entries, dup_slice(token, token_len));
            }
            total_words++;
            token_len = 0;
        }
    }

    if (token_len > 0) {
        token[token_len] = '\0';
        int found = 0;
        for (size_t j = 0; j < entries.len; j++) {
            if (strcmp(entries.items[j].word, token) == 0) {
                entries.items[j].count++;
                found = 1;
                break;
            }
        }
        if (!found) {
            vec_push(&entries, dup_slice(token, token_len));
        }
        total_words++;
    }

    qsort(entries.items, entries.len, sizeof(Entry), cmp_entry_desc_count_asc_word);

    size_t top_n = entries.len < 10 ? entries.len : 10;
    for (size_t i = 0; i < top_n; i++) {
        printf("%zu\t%s\n", entries.items[i].count, entries.items[i].word);
    }
    printf("--\n");
    printf("total\t%zu\n", total_words);
    printf("unique\t%zu\n", entries.len);

    for (size_t i = 0; i < entries.len; i++) {
        free(entries.items[i].word);
    }
    free(entries.items);
    free(token);
    return 0;
}
