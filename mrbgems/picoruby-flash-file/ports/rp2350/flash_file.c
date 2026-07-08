/*
 * Memory-mapped base of the LittleFS partition on the Harucom Board.
 * FLASH_MMAP_ADDR comes from include/disk.h, the same mapping the
 * LittleFS flash HAL reads through (ports/picoruby-littlefs).
 */

#include "disk.h"
#include "flash_file.h"

const uint8_t *
flash_file_filesystem_base(void)
{
  return (const uint8_t *)FLASH_MMAP_ADDR;
}
