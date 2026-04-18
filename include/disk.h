#ifndef DISK_DEFINED_H_
#define DISK_DEFINED_H_

#include <hardware/flash.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Harucom Board: 16 MB flash
 *   First  8 MB (0x00000000 - 0x007FFFFF): firmware (code, data, fonts)
 *   Last   8 MB (0x00800000 - 0x00FFFFFF): LittleFS filesystem
 */
#define FLASH_TARGET_OFFSET 0x00800000 /* 8 MB offset for filesystem */
#define FLASH_MMAP_ADDR     (XIP_BASE + FLASH_TARGET_OFFSET)
/* FLASH_SECTOR_SIZE is 4096, defined in hardware/flash.h */
#define FLASH_SECTOR_COUNT 2048 /* 8 MB / 4096 = 2048 sectors */

#ifdef __cplusplus
}
#endif

#endif /* DISK_DEFINED_H_ */
