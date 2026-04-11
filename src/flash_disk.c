/*
 * Flash disk driver for FatFs on RP2350 (Harucom Board, 16 MB flash).
 *
 * DVI blanking is enabled before flash operations to ensure Core 1
 * does not access flash-resident data during XIP-disabled window.
 * Core 0 interrupts are disabled during flash_range_erase/program
 * to prevent flash-resident IRQ handlers from running.
 */

#include <string.h>

#include "ff.h"
#include "diskio.h"

#include <hardware/sync.h>
#include <hardware/flash.h>

#include "disk.h"
#include "dvi.h"

/* Check if DVI is running by examining the frame counter.
 * When DVI has not started, frame_count stays at 0 and
 * dvi_wait_vsync() would hang forever. */
static bool
dvi_is_running(void)
{
    return dvi_get_frame_count() > 0;
}

int
FLASH_disk_erase(void)
{
    bool dvi = dvi_is_running();
    if (dvi) {
        dvi_set_blanking(true);
        dvi_wait_vsync();
    }

    uint32_t ints = save_and_disable_interrupts();
    flash_range_erase(
        (uint32_t)FLASH_TARGET_OFFSET,
        (size_t)(FLASH_SECTOR_SIZE * FLASH_SECTOR_COUNT)
    );
    restore_interrupts(ints);

    if (dvi) {
        dvi_set_blanking(false);
        dvi_wait_vsync();
    }
    return 0;
}

int
FLASH_disk_initialize(void)
{
    /* Flash ROM is always ready */
    return 0;
}

int
FLASH_disk_status(void)
{
    /* Flash ROM is always ready */
    return 0;
}

int
FLASH_disk_read(BYTE *buff, LBA_t sector, UINT count)
{
    memcpy(
        buff,
        (uint8_t *)(FLASH_MMAP_ADDR + sector * FLASH_SECTOR_SIZE),
        count * FLASH_SECTOR_SIZE
    );
    return 0;
}

int
FLASH_disk_write(const BYTE *buff, LBA_t sector, UINT count)
{
    uint32_t offset = FLASH_TARGET_OFFSET + sector * FLASH_SECTOR_SIZE;
    size_t size = (size_t)(FLASH_SECTOR_SIZE * count);

    bool dvi = dvi_is_running();
    if (dvi) {
        dvi_set_blanking(true);
        dvi_wait_vsync();
    }

    uint32_t ints = save_and_disable_interrupts();
    flash_range_erase(offset, size);
    restore_interrupts(ints);

    /* Copy buffer from PSRAM to SRAM before programming.
     * flash_range_program puts QMI into flash command mode (CS0),
     * which makes PSRAM (QMI CS1) inaccessible. */
    static uint8_t sram_buf[FLASH_SECTOR_SIZE];
    for (UINT i = 0; i < count; i++) {
        memcpy(sram_buf, (const uint8_t *)buff + i * FLASH_SECTOR_SIZE,
               FLASH_SECTOR_SIZE);
        ints = save_and_disable_interrupts();
        flash_range_program(offset + i * FLASH_SECTOR_SIZE, sram_buf,
                            FLASH_SECTOR_SIZE);
        restore_interrupts(ints);
    }

    if (dvi) {
        dvi_set_blanking(false);
        dvi_wait_vsync();
    }
    return 0;
}

DRESULT
FLASH_disk_ioctl(BYTE cmd, void *buff)
{
    switch (cmd) {
    case CTRL_SYNC:
        break;
    case GET_BLOCK_SIZE:
        *((DWORD *)buff) = 1;
        break;
    case CTRL_TRIM:
        return RES_ERROR;
    case GET_SECTOR_SIZE:
        *((WORD *)buff) = (WORD)FLASH_SECTOR_SIZE;
        break;
    case GET_SECTOR_COUNT:
        *((LBA_t *)buff) = (LBA_t)FLASH_SECTOR_COUNT;
        break;
    default:
        return RES_PARERR;
    }
    return RES_OK;
}


#if FF_MAX_SS == FF_MIN_SS
#define SS(fs) ((UINT)FF_MAX_SS)
#else
#define SS(fs) ((fs)->ssize)
#endif

static LBA_t clst2sect(FATFS *fs, DWORD clst)
{
    clst -= 2;
    if (clst >= fs->n_fatent - 2) return 0;
    return fs->database + (LBA_t)fs->csize * clst;
}

void
FILE_physical_address(FIL *fp, uint8_t **addr)
{
    FATFS *fs = fp->obj.fs;
    LBA_t sect = clst2sect(fs, fp->obj.sclust);
    *addr = (uint8_t *)(FLASH_MMAP_ADDR + sect * FLASH_SECTOR_SIZE);
}

int
FILE_sector_size(void)
{
    return FLASH_SECTOR_SIZE;
}
