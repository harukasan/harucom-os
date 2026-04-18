/*
 * LittleFS flash HAL for Harucom Board (RP2350, 16 MB flash).
 *
 * Filesystem region: 0x00800000, 8 MB (2048 blocks of 4096 bytes),
 * as declared in include/disk.h.
 *
 * Program source buffers may live in PSRAM (QMI CS1). flash_range_program
 * puts QMI into flash command mode (CS0), which makes PSRAM inaccessible,
 * so the buffer is first copied into a static SRAM staging buffer before
 * programming.  Core 0 interrupts are disabled during flash_range_erase
 * and flash_range_program to prevent flash-resident IRQ handlers from
 * running while XIP is down.
 */

#include <string.h>

#include <hardware/flash.h>
#include <hardware/sync.h>
#include <pico/assert.h>
#include <pico/platform.h>

#include "disk.h"
#include "lfs.h"
#include "littlefs.h"

#define LFS_FLASH_BLOCK_SIZE FLASH_SECTOR_SIZE
#define LFS_FLASH_BLOCK_COUNT FLASH_SECTOR_COUNT

/* Sized to match prog_size below.  Callers (Core 0, cooperative tasks)
 * serialize access, so a single static buffer is safe. */
static uint8_t sram_staging_buf[FLASH_PAGE_SIZE];

static int lfs_flash_read(const struct lfs_config *c, lfs_block_t block,
                          lfs_off_t off, void *buffer, lfs_size_t size) {
  memcpy(buffer,
         (const uint8_t *)(FLASH_MMAP_ADDR + block * c->block_size + off),
         size);
  return LFS_ERR_OK;
}

static int lfs_flash_prog(const struct lfs_config *c, lfs_block_t block,
                          lfs_off_t off, const void *buffer,
                          lfs_size_t size) {
  /* Only Core 0 may write flash: Core 1 serves DVI and must stay in SRAM
   * while XIP is disabled, and the static staging buffer below is not
   * reentrancy-safe. */
  hard_assert(get_core_num() == 0);
  uint32_t addr = FLASH_TARGET_OFFSET + block * c->block_size + off;
  lfs_size_t remaining = size;
  const uint8_t *src = (const uint8_t *)buffer;

  while (remaining > 0) {
    lfs_size_t chunk =
        remaining > sizeof(sram_staging_buf) ? sizeof(sram_staging_buf)
                                             : remaining;
    memcpy(sram_staging_buf, src, chunk);
    uint32_t ints = save_and_disable_interrupts();
    flash_range_program(addr, sram_staging_buf, chunk);
    restore_interrupts(ints);
    addr += chunk;
    src += chunk;
    remaining -= chunk;
  }
  return LFS_ERR_OK;
}

static int lfs_flash_erase(const struct lfs_config *c, lfs_block_t block) {
  hard_assert(get_core_num() == 0);
  uint32_t addr = FLASH_TARGET_OFFSET + block * c->block_size;
  uint32_t ints = save_and_disable_interrupts();
  flash_range_erase(addr, c->block_size);
  restore_interrupts(ints);
  return LFS_ERR_OK;
}

static int lfs_flash_sync(const struct lfs_config *c) {
  (void)c;
  return LFS_ERR_OK;
}

void littlefs_hal_init_config(struct lfs_config *cfg) {
  memset(cfg, 0, sizeof(struct lfs_config));
  cfg->read = lfs_flash_read;
  cfg->prog = lfs_flash_prog;
  cfg->erase = lfs_flash_erase;
  cfg->sync = lfs_flash_sync;

  cfg->read_size = FLASH_PAGE_SIZE;
  cfg->prog_size = FLASH_PAGE_SIZE;
  cfg->block_size = LFS_FLASH_BLOCK_SIZE;
  cfg->block_count = LFS_FLASH_BLOCK_COUNT;
  cfg->block_cycles = 500;
  cfg->cache_size = FLASH_PAGE_SIZE;
  cfg->lookahead_size = 16;
}

void littlefs_hal_erase_all(void) {
  hard_assert(get_core_num() == 0);
  uint32_t ints = save_and_disable_interrupts();
  flash_range_erase((uint32_t)FLASH_TARGET_OFFSET,
                    (size_t)(LFS_FLASH_BLOCK_SIZE * LFS_FLASH_BLOCK_COUNT));
  restore_interrupts(ints);
}
