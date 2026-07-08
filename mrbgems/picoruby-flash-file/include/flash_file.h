#ifndef FLASH_FILE_DEFINED_H_
#define FLASH_FILE_DEFINED_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Platform-specific: memory-mapped base address of the LittleFS
 * flash partition (block 0). */
const uint8_t *flash_file_filesystem_base(void);

#ifdef __cplusplus
}
#endif

#endif /* FLASH_FILE_DEFINED_H_ */
