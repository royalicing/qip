#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *word;
    size_t len;
    size_t count;
    uint64_t hash;
    int used;
} Slot;

typedef struct {
    Slot *slots;
    size_t cap;
    size_t len;
} Table;

typedef struct {
    const char *word;
    size_t count;
} Entry;

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

static uint64_t fnv1a(const char *s, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= (unsigned char)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static size_t next_pow2(size_t n) {
    size_t p = 1;
    while (p < n) {
        p <<= 1;
    }
    return p;
}

static void table_init(Table *t, size_t cap) {
    t->cap = next_pow2(cap < 16 ? 16 : cap);
    t->len = 0;
    t->slots = (Slot *)calloc(t->cap, sizeof(Slot));
    if (!t->slots) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
}

static void table_free(Table *t) {
    if (!t->slots) return;
    for (size_t i = 0; i < t->cap; i++) {
        if (t->slots[i].used) {
            free(t->slots[i].word);
        }
    }
    free(t->slots);
    t->slots = NULL;
    t->cap = 0;
    t->len = 0;
}

static Slot *table_find_slot(Table *t, const char *word, size_t len, uint64_t hash) {
    size_t mask = t->cap - 1;
    size_t i = (size_t)hash & mask;
    while (1) {
        Slot *s = &t->slots[i];
        if (!s->used) {
            return s;
        }
        if (s->hash == hash && s->len == len && memcmp(s->word, word, len) == 0) {
            return s;
        }
        i = (i + 1) & mask;
    }
}

static void table_rehash(Table *t, size_t new_cap) {
    Table next;
    table_init(&next, new_cap);

    for (size_t i = 0; i < t->cap; i++) {
        Slot *old = &t->slots[i];
        if (!old->used) continue;

        Slot *dst = table_find_slot(&next, old->word, old->len, old->hash);
        dst->used = 1;
        dst->word = old->word;
        dst->len = old->len;
        dst->count = old->count;
        dst->hash = old->hash;
        next.len++;

        old->word = NULL;
        old->used = 0;
    }

    free(t->slots);
    *t = next;
}

static void table_maybe_grow(Table *t) {
    if ((t->len + 1) * 10 >= t->cap * 7) {
        table_rehash(t, t->cap * 2);
    }
}

static void table_add(Table *t, const char *word, size_t len) {
    uint64_t hash = fnv1a(word, len);
    table_maybe_grow(t);

    Slot *s = table_find_slot(t, word, len, hash);
    if (s->used) {
        s->count++;
        return;
    }

    s->used = 1;
    s->word = dup_slice(word, len);
    s->len = len;
    s->count = 1;
    s->hash = hash;
    t->len++;
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
    Table table;
    table_init(&table, 1024);

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
                table_free(&table);
                free(token);
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

            table_add(&table, token, token_len);
            total_words++;
            token_len = 0;
        }
    }

    if (token_len > 0) {
        table_add(&table, token, token_len);
        total_words++;
    }

    Entry *entries = (Entry *)xmalloc(table.len * sizeof(Entry));
    size_t idx = 0;
    for (size_t i = 0; i < table.cap; i++) {
        Slot *s = &table.slots[i];
        if (!s->used) continue;
        entries[idx].word = s->word;
        entries[idx].count = s->count;
        idx++;
    }

    qsort(entries, table.len, sizeof(Entry), cmp_entry_desc_count_asc_word);

    size_t top_n = table.len < 10 ? table.len : 10;
    for (size_t i = 0; i < top_n; i++) {
        printf("%zu\t%s\n", entries[i].count, entries[i].word);
    }
    printf("--\n");
    printf("total\t%zu\n", total_words);
    printf("unique\t%zu\n", table.len);

    free(entries);
    table_free(&table);
    free(token);
    return 0;
}
