/*
 * RP2350 dictionary location.
 *
 * The dictionary is a separate flash image, written independently from the
 * firmware via picotool, and the chip maps it into the address space through
 * XIP. So there is nothing to load: the parse and lookup code in
 * src/dict_lookup.c reads it in place from the address below.
 */

#include <hardware/flash.h>

#include "dict_region.h"

const uint8_t *
dict_region_base(void)
{
  return (const uint8_t *)(uintptr_t)(XIP_BASE + DICT_FLASH_OFFSET);
}
