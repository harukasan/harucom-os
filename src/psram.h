#ifndef PSRAM_H
#define PSRAM_H

#include <stddef.h>

/*
 * Initialize the APS6404L-3SQR-SN PSRAM (8 MB) connected to QMI CS1.
 *
 * Configures the QMI memory window 1 for quad-SPI access and maps the
 * PSRAM into the XIP address space via ATRANS.
 *
 * Returns the memory-mapped base address, or NULL on failure.
 * If size_out is non-NULL, it receives the usable size in bytes.
 */
void *psram_init(size_t *size_out);

#endif /* PSRAM_H */
