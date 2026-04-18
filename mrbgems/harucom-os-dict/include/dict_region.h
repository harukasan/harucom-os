#ifndef DICT_REGION_H_
#define DICT_REGION_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Dictionary region: 2 MB at the end of the firmware area, just before the
 * LittleFS filesystem.
 *
 *   0x00600000 - 0x007FFFFF: dictionary data (separate UF2)
 *
 * Written independently from firmware via picotool. The firmware reads
 * this region through XIP (memory-mapped flash) without any file I/O.
 */
#define DICT_FLASH_OFFSET 0x00600000
#define DICT_REGION_SIZE  (2 * 1024 * 1024) /* 2 MB */
#define DICT_MAGIC        0x4B444348        /* "HCDK" */

/* Section types */
#define DICT_TYPE_SKK   1
#define DICT_TYPE_TCODE 2

/* Global header at the start of the dictionary region */
typedef struct {
  uint32_t magic;
  uint32_t version;
  uint32_t section_count;
} dict_header_t;

/* Section descriptor (follows header, repeated section_count times) */
typedef struct {
  uint32_t type;
  uint32_t offset; /* byte offset from dict_header_t start */
  uint32_t size;   /* section data size in bytes */
} dict_section_t;

/* SKK dictionary section header */
typedef struct {
  uint32_t bucket_count;
  uint32_t entry_count;
} dict_skk_header_t;

/* T-Code table section header */
typedef struct {
  uint32_t key_count; /* 40 for standard T-Code */
} dict_tcode_header_t;

/* Check whether the dictionary region contains valid data */
int dict_available(void);

/* Find a section by type. Returns pointer to section data, or NULL. */
const void *dict_find_section(uint32_t type, uint32_t *out_size);

/*
 * SKK dictionary lookup.
 * Returns the number of candidates found (0 if not found).
 * Candidate pointers and lengths are written to out_candidates/out_lengths
 * (up to max_candidates).
 */
int dict_skk_lookup(const char *reading, int reading_len, const char **out_candidates,
                    int *out_lengths, int max_candidates);

/*
 * T-Code table lookup.
 * Returns the Unicode codepoint for the two-stroke sequence, or 0 if
 * no character is assigned.
 */
uint16_t dict_tcode_lookup(int key1, int key2);

#ifdef __cplusplus
}
#endif

#endif /* DICT_REGION_H_ */
