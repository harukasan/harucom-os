/*
 * Initialize the root filesystem on flash.
 *
 * At build time, scripts/gen_ruby_scripts.rb converts rootfs/ files into
 * C byte arrays and a CRC32 hash in ruby_scripts.h.
 *
 * On boot, this module checks ROOTFS_HASH on the FAT volume against
 * the firmware-embedded hash.  If they match, file deployment is
 * skipped (fast boot).  On mismatch (first boot or firmware update),
 * all files are written and the marker is updated.
 *
 * The marker file is written last so that an interrupted deployment
 * (power loss) is detected as a missing/stale marker on next boot.
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "ff.h"
#include "init_rootfs.h"
#include "ruby_scripts.h"

#define ROOTFS_MARKER_PATH "flash:ROOTFS_HASH"

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
  const MKFS_PARM opt = {FM_FAT, 1, 0, 0, 0};
  FRESULT res = f_mkfs("flash:", &opt, work, sizeof(work));
  if (res != FR_OK) {
    printf("rootfs: f_mkfs failed (%d)\n", res);
    return res;
  }
  return f_mount(fatfs, "flash:", 1);
}

/* Read the rootfs hash marker from the FAT volume. */
static bool
read_rootfs_marker(uint32_t *hash)
{
  FIL fp;
  if (f_open(&fp, ROOTFS_MARKER_PATH, FA_READ) != FR_OK) return false;
  UINT br;
  FRESULT res = f_read(&fp, hash, sizeof(*hash), &br);
  f_close(&fp);
  return res == FR_OK && br == sizeof(*hash);
}

/* Write the rootfs hash marker to the FAT volume. */
static void
write_rootfs_marker(void)
{
  FIL fp;
  if (f_open(&fp, ROOTFS_MARKER_PATH, FA_CREATE_ALWAYS | FA_WRITE) != FR_OK) return;
  uint32_t hash = rootfs_hash;
  UINT bw;
  f_write(&fp, &hash, sizeof(hash), &bw);
  f_close(&fp);
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
      printf("rootfs: f_write(%s) failed (%d, wrote %u/%u)\n", entry->path, res, bw, entry->size);
      ok = false;
    }
    f_close(&fp);
    printf("rootfs: %s (%u bytes)\n", entry->path, entry->size);
  }
  return ok;
}

/* Deploy all rootfs files and write the marker last. */
static void
deploy_all(FATFS *fatfs)
{
  if (!write_scripts()) {
    printf("rootfs: write errors, reformatting...\n");
    if (format_and_mount(fatfs) != FR_OK) return;
    write_scripts();
  }
  write_rootfs_marker();
  printf("rootfs: deployed (%d files, hash %08lx)\n", ruby_scripts_count,
         (unsigned long)rootfs_hash);
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
    if (res != FR_OK) {
      printf("rootfs: format_and_mount failed (%d)\n", res);
      return;
    }
    deploy_all(&fatfs);
    goto done;
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
    deploy_all(&fatfs);
    goto done;
  }

  /* Check rootfs hash marker */
  uint32_t stored_hash;
  if (read_rootfs_marker(&stored_hash) && stored_hash == rootfs_hash) {
    printf("rootfs: up to date (%08lx)\n", (unsigned long)rootfs_hash);
  } else {
    printf("rootfs: updating...\n");
    deploy_all(&fatfs);
  }

done:
  f_mount(NULL, "flash:", 0);
}
