/*
 * picoruby-flash-file/src/flash_file.c
 *
 * FlashFile maps a file on the LittleFS partition to the list of
 * flash memory ranges holding its data, so readers (e.g. the PWM
 * audio sample streamer) can consume the file straight from
 * memory-mapped flash without copying it into RAM.
 */

#include "../include/flash_file.h"

#if defined(PICORB_VM_MRUBY)
#include "mruby/flash_file.c"
#endif
