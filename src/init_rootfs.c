/*
 * Initialize the root filesystem on flash.
 *
 * At build time, scripts/gen_ruby_scripts.rb converts rootfs/*.rb into
 * C byte arrays in ruby_scripts.h.  This module writes them to the
 * FatFs volume at boot, before the mruby VM starts.
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "ff.h"
#include "init_rootfs.h"
#include "ruby_scripts.h"

/* Ensure parent directories exist for a FatFs path like "flash:lib/foo.rb". */
static void
ensure_directories(const char *path)
{
    /* Find the start of the relative path after "flash:" */
    const char *rel = strchr(path, ':');
    if (!rel) return;
    rel++; /* skip ':' */

    /* Work buffer: "flash:" + directory components */
    char buf[128];
    size_t prefix_len = (size_t)(rel - path);
    if (prefix_len >= sizeof(buf)) return;
    memcpy(buf, path, prefix_len);

    const char *p = rel;
    while (*p) {
        const char *slash = strchr(p, '/');
        if (!slash) break;
        size_t dir_len = (size_t)(slash - rel);
        if (prefix_len + dir_len >= sizeof(buf)) break;
        memcpy(buf + prefix_len, rel, dir_len);
        buf[prefix_len + dir_len] = '\0';
        f_mkdir(buf); /* ignore errors (already exists is OK) */
        p = slash + 1;
    }
}

static FRESULT
format_and_mount(FATFS *fatfs)
{
    printf("rootfs: formatting...\n");
    f_mount(NULL, "flash:", 0);
    static uint8_t work[FF_MAX_SS];
    const MKFS_PARM opt = { FM_FAT, 1, 0, 0, 0 };
    FRESULT res = f_mkfs("flash:", &opt, work, sizeof(work));
    if (res != FR_OK) {
        printf("rootfs: f_mkfs failed (%d)\n", res);
        return res;
    }
    return f_mount(fatfs, "flash:", 1);
}

/* Write all scripts to flash. Returns true if all writes succeeded. */
static bool
write_scripts(void)
{
    bool ok = true;
    for (int i = 0; i < ruby_scripts_count; i++) {
        const ruby_script_entry_t *entry = &ruby_scripts[i];

        ensure_directories(entry->path);

        FIL fp;
        UINT bw;
        FRESULT res = f_open(&fp, entry->path, FA_CREATE_ALWAYS | FA_WRITE);
        if (res != FR_OK) {
            printf("rootfs: f_open(%s) failed (%d)\n", entry->path, res);
            ok = false;
            continue;
        }
        res = f_write(&fp, entry->data, entry->size, &bw);
        if (res != FR_OK || bw != entry->size) {
            printf("rootfs: f_write(%s) failed (%d, wrote %u/%u)\n",
                   entry->path, res, bw, entry->size);
            ok = false;
        }
        f_close(&fp);
        printf("rootfs: %s (%u bytes)\n", entry->path, entry->size);
    }
    return ok;
}

void
init_rootfs(void)
{
    FATFS fatfs;
    FRESULT res;

    /* Mount the flash volume */
    res = f_mount(&fatfs, "flash:", 1);
    if (res == FR_NO_FILESYSTEM) {
        res = format_and_mount(&fatfs);
    }
    if (res != FR_OK) {
        printf("rootfs: f_mount failed (%d)\n", res);
        return;
    }

    /* Reformat if trigger file exists (created by user via "touch /FORMAT") */
    FILINFO fno;
    if (f_stat("flash:FORMAT", &fno) == FR_OK) {
        printf("rootfs: format trigger found, reformatting...\n");
        res = format_and_mount(&fatfs);
        if (res != FR_OK) {
            printf("rootfs: reformat failed (%d)\n", res);
            return;
        }
    }

    /* Write all scripts; reformat and retry once on failure */
    if (!write_scripts()) {
        printf("rootfs: write errors detected, reformatting...\n");
        res = format_and_mount(&fatfs);
        if (res != FR_OK) {
            printf("rootfs: reformat failed (%d)\n", res);
            return;
        }
        write_scripts();
    }

    /* Unmount (Ruby bootstrap will re-mount via VFS) */
    f_mount(NULL, "flash:", 0);
    printf("rootfs: done (%d files)\n", ruby_scripts_count);
}
