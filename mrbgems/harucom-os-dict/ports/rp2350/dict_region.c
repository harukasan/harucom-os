#include <string.h>
#include <hardware/flash.h>

#include "dict_region.h"

/* XIP-mapped base address for dictionary region */
#define DICT_XIP_BASE  (XIP_BASE + DICT_FLASH_OFFSET)

/* FNV-1a hash (same algorithm used by the dictionary packing tool) */
static uint32_t fnv1a(const char *data, int len)
{
    uint32_t hash = 0x811c9dc5;
    for (int i = 0; i < len; i++) {
        hash ^= (uint8_t)data[i];
        hash *= 0x01000193;
    }
    return hash;
}

static const dict_header_t *get_header(void)
{
    return (const dict_header_t *)(uintptr_t)DICT_XIP_BASE;
}

int dict_available(void)
{
    const dict_header_t *h = get_header();
    return h->magic == DICT_MAGIC;
}

const void *dict_find_section(uint32_t type, uint32_t *out_size)
{
    const dict_header_t *h = get_header();
    if (h->magic != DICT_MAGIC)
        return NULL;

    const dict_section_t *sections =
        (const dict_section_t *)((const uint8_t *)h + sizeof(dict_header_t));

    for (uint32_t i = 0; i < h->section_count; i++) {
        if (sections[i].type == type) {
            if (out_size)
                *out_size = sections[i].size;
            return (const uint8_t *)h + sections[i].offset;
        }
    }
    return NULL;
}

/*
 * Encode a UTF-8 hiragana reading into compact 1-byte-per-kana form.
 * Hiragana U+3041..U+3096 becomes 0x01..0x56. ASCII bytes pass through.
 * Returns the encoded length, or -1 if the buffer is too small.
 */
static int encode_reading(const char *utf8, int utf8_len,
                          uint8_t *out, int out_cap)
{
    int si = 0, di = 0;
    const uint8_t *src = (const uint8_t *)utf8;
    while (si < utf8_len && di < out_cap) {
        uint8_t b = src[si];
        if (b < 0x80) {
            /* ASCII */
            out[di++] = b;
            si++;
        } else if (b >= 0xE0 && si + 2 < utf8_len) {
            /* 3-byte UTF-8 */
            uint32_t cp = ((b & 0x0F) << 12) |
                          ((src[si + 1] & 0x3F) << 6) |
                          (src[si + 2] & 0x3F);
            if (cp >= 0x3041 && cp <= 0x3096) {
                out[di++] = (uint8_t)(cp - 0x3041 + 1);
            } else {
                /* Non-hiragana: copy raw UTF-8 */
                if (di + 3 > out_cap) return -1;
                out[di++] = src[si];
                out[di++] = src[si + 1];
                out[di++] = src[si + 2];
            }
            si += 3;
        } else if (b >= 0xC0 && si + 1 < utf8_len) {
            /* 2-byte UTF-8 */
            if (di + 2 > out_cap) return -1;
            out[di++] = src[si];
            out[di++] = src[si + 1];
            si += 2;
        } else {
            out[di++] = b;
            si++;
        }
    }
    return di;
}

int dict_skk_lookup(const char *reading, int reading_len,
                    const char **out_candidates, int *out_lengths,
                    int max_candidates)
{
    uint32_t section_size;
    const uint8_t *section = dict_find_section(DICT_TYPE_SKK, &section_size);
    if (!section)
        return 0;

    const dict_skk_header_t *skk = (const dict_skk_header_t *)section;
    uint32_t bucket_count = skk->bucket_count;
    if (bucket_count == 0)
        return 0;

    /* Encode the UTF-8 reading to compact form for hash and comparison */
    uint8_t encoded[128];
    int encoded_len = encode_reading(reading, reading_len, encoded, sizeof(encoded));
    if (encoded_len < 0)
        return 0;

    const uint32_t *buckets =
        (const uint32_t *)(section + sizeof(dict_skk_header_t));

    uint32_t bucket_idx = fnv1a((const char *)encoded, encoded_len) % bucket_count;
    uint32_t offset = buckets[bucket_idx];

    while (offset != 0) {
        const uint8_t *entry = section + offset;
        uint32_t next;
        memcpy(&next, entry, 4);
        uint8_t rlen = entry[4];
        uint8_t ccount = entry[5];
        const uint8_t *r = entry + 6;

        if (rlen == encoded_len && memcmp(r, encoded, encoded_len) == 0) {
            /* Match: extract candidates */
            const uint8_t *p = r + rlen;
            int count = 0;
            for (int i = 0; i < ccount && count < max_candidates; i++) {
                uint8_t clen = *p++;
                out_candidates[count] = (const char *)p;
                out_lengths[count] = clen;
                count++;
                p += clen;
            }
            return count;
        }

        offset = next;
    }

    return 0;
}

uint16_t dict_tcode_lookup(int key1, int key2)
{
    uint32_t section_size;
    const uint8_t *section = dict_find_section(DICT_TYPE_TCODE, &section_size);
    if (!section)
        return 0;

    const dict_tcode_header_t *tcode = (const dict_tcode_header_t *)section;
    int key_count = (int)tcode->key_count;

    if (key1 < 0 || key1 >= key_count || key2 < 0 || key2 >= key_count)
        return 0;

    const uint16_t *table =
        (const uint16_t *)(section + sizeof(dict_tcode_header_t));
    return table[key1 * key_count + key2];
}
