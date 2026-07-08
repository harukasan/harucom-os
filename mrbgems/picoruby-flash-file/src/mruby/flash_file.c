/*
 * picoruby-flash-file/src/mruby/flash_file.c
 *
 * Ruby bindings for the FlashFile module.
 */

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/presym.h>
#include <mruby/string.h>

#include <littlefs.h>

/* LittleFS stores file data as a CTZ skip list: block index 0 is all
 * data; every block index i >= 1 begins with ctz(i)+1 little-endian
 * u32 pointers (the first one pointing at block i-1), followed by
 * data. The list is walked backward from the head block recorded in
 * the file's metadata. See littlefs DESIGN.md ("CTZ skip-lists") and
 * lfs_ctz_index in lfs.c, which this layout math mirrors. */

static uint32_t
ctz_pointer_words(uint32_t block_index)
{
  if (block_index == 0) return 0;
  return (uint32_t)__builtin_ctz(block_index) + 1;
}

static uint32_t
read_u32le(const uint8_t *p)
{
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void
write_u32le(uint8_t *p, uint32_t value)
{
  p[0] = (uint8_t)value;
  p[1] = (uint8_t)(value >> 8);
  p[2] = (uint8_t)(value >> 16);
  p[3] = (uint8_t)(value >> 24);
}

/* FlashFile.extents(path): [extents, bytesize] for a file on the
 * LittleFS partition. extents is a String of packed little-endian
 * (u32 address, u32 length) pairs covering the file's data in order,
 * each address pointing into memory-mapped flash. Returns nil when
 * the file is stored inline in directory metadata (small files),
 * which has no stable flash location. The map stays valid until the
 * file is rewritten; writing a file moves its blocks. */
static mrb_value
mrb_flash_file_extents(mrb_state *mrb, mrb_value self)
{
  const char *path;
  mrb_get_args(mrb, "z", &path);

  int err = littlefs_ensure_mounted();
  if (err != 0) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "filesystem is not mounted");
  }
  lfs_t *lfs = littlefs_get_lfs();

  lfs_file_t file;
  err = lfs_file_open(lfs, &file, path, LFS_O_RDONLY);
  if (err != LFS_ERR_OK) {
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "cannot open %s", path);
  }
  uint32_t flags = file.flags;
  uint32_t head = file.ctz.head;
  uint32_t size = file.ctz.size;
  lfs_file_close(lfs, &file);

  if (flags & LFS_F_INLINE) return mrb_nil_value();
  if (size == 0) return mrb_nil_value();

  const struct lfs_config *config = littlefs_get_config();
  uint32_t block_size = config->block_size;
  uint32_t block_count = config->block_count;
  const uint8_t *base = flash_file_filesystem_base();

  /* Count the blocks the file spans. */
  uint32_t blocks = 0;
  uint32_t covered = 0;
  while (covered < size) {
    if (blocks >= block_count) {
      mrb_raise(mrb, E_RUNTIME_ERROR, "corrupt file: size exceeds the partition");
    }
    covered += block_size - 4 * ctz_pointer_words(blocks);
    blocks++;
  }

  /* Allocate the result String before the temporary block list, so a
   * raise from the allocator cannot leak the list. */
  mrb_value extents = mrb_str_new(mrb, NULL, blocks * 8);

  /* Walk the skip list backward from the head to list every block. */
  uint32_t *block_list = (uint32_t *)mrb_malloc(mrb, blocks * sizeof(uint32_t));
  block_list[blocks - 1] = head;
  for (uint32_t i = blocks - 1; i > 0; i--) {
    if (block_list[i] >= block_count) {
      mrb_free(mrb, block_list);
      mrb_raise(mrb, E_RUNTIME_ERROR, "corrupt file: block out of range");
    }
    block_list[i - 1] = read_u32le(base + block_list[i] * block_size);
  }
  if (block_list[0] >= block_count) {
    mrb_free(mrb, block_list);
    mrb_raise(mrb, E_RUNTIME_ERROR, "corrupt file: block out of range");
  }

  uint8_t *out = (uint8_t *)RSTRING_PTR(extents);
  uint32_t remaining = size;
  for (uint32_t i = 0; i < blocks; i++) {
    uint32_t pointer_bytes = 4 * ctz_pointer_words(i);
    uint32_t capacity = block_size - pointer_bytes;
    uint32_t length = remaining < capacity ? remaining : capacity;
    uint32_t address = (uint32_t)(uintptr_t)(base + block_list[i] * block_size + pointer_bytes);
    write_u32le(out + i * 8, address);
    write_u32le(out + i * 8 + 4, length);
    remaining -= length;
  }
  mrb_free(mrb, block_list);

  mrb_value result = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, result, extents);
  mrb_ary_push(mrb, result, mrb_int_value(mrb, (mrb_int)size));
  return result;
}

void
mrb_picoruby_flash_file_gem_init(mrb_state *mrb)
{
  struct RClass *module_FlashFile = mrb_define_module_id(mrb, MRB_SYM(FlashFile));
  mrb_define_module_function_id(mrb, module_FlashFile, MRB_SYM(extents), mrb_flash_file_extents,
                                MRB_ARGS_REQ(1));
}

void
mrb_picoruby_flash_file_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
