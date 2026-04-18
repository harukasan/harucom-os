/*
 * Initialize the root filesystem on flash using LittleFS.
 *
 * At build time, scripts/gen_ruby_scripts.rb converts rootfs/ files into
 * C byte arrays and a CRC32 hash in ruby_scripts.h.
 *
 * On boot, this module mounts the LittleFS volume (auto-formatting on
 * LFS_ERR_CORRUPT), then checks ROOTFS_HASH against the firmware-embedded
 * hash.  If they match, file deployment is skipped (fast boot).  On
 * mismatch (first boot or firmware update), all files are rewritten and
 * the marker is updated last.
 *
 * The marker file is written last so that an interrupted deployment
 * (power loss) is detected as a missing/stale marker on next boot.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "init_rootfs.h"
#include "lfs.h"
#include "littlefs.h"
#include "ruby_scripts.h"

#define ROOTFS_MARKER_PATH "/ROOTFS_HASH"
#define FORMAT_TRIGGER_PATH "/FORMAT"

/* Create parent directories for an absolute path like "/lib/foo.rb". */
static void ensure_directories(lfs_t *lfs, const char *path) {
  char buf[LFS_NAME_MAX + 1];
  const char *p = path;
  if (*p == '/') p++;
  while (*p) {
    const char *slash = strchr(p, '/');
    if (!slash) break;
    size_t prefix_len = (size_t)(slash - path);
    if (prefix_len >= sizeof(buf)) {
      printf("rootfs: path too long, skipping mkdir: %s\n", path);
      return;
    }
    memcpy(buf, path, prefix_len);
    buf[prefix_len] = '\0';
    lfs_mkdir(lfs, buf); /* ignore errors (EXIST is OK) */
    p = slash + 1;
  }
}

static bool read_rootfs_marker(lfs_t *lfs, uint32_t *hash) {
  lfs_file_t fp;
  if (lfs_file_open(lfs, &fp, ROOTFS_MARKER_PATH, LFS_O_RDONLY) !=
      LFS_ERR_OK) {
    return false;
  }
  lfs_ssize_t br = lfs_file_read(lfs, &fp, hash, sizeof(*hash));
  lfs_file_close(lfs, &fp);
  return br == (lfs_ssize_t)sizeof(*hash);
}

static void write_rootfs_marker(lfs_t *lfs) {
  lfs_file_t fp;
  if (lfs_file_open(lfs, &fp, ROOTFS_MARKER_PATH,
                    LFS_O_WRONLY | LFS_O_CREAT | LFS_O_TRUNC) != LFS_ERR_OK) {
    return;
  }
  uint32_t hash = rootfs_hash;
  lfs_file_write(lfs, &fp, &hash, sizeof(hash));
  lfs_file_close(lfs, &fp);
}

static bool write_scripts(lfs_t *lfs) {
  bool ok = true;
  for (int i = 0; i < ruby_scripts_count; i++) {
    const ruby_script_entry_t *entry = &ruby_scripts[i];
    ensure_directories(lfs, entry->path);

    lfs_file_t fp;
    int err = lfs_file_open(lfs, &fp, entry->path,
                            LFS_O_WRONLY | LFS_O_CREAT | LFS_O_TRUNC);
    if (err != LFS_ERR_OK) {
      printf("rootfs: lfs_file_open(%s) failed (%d)\n", entry->path, err);
      ok = false;
      continue;
    }
    lfs_ssize_t bw = lfs_file_write(lfs, &fp, entry->data, entry->size);
    if (bw != (lfs_ssize_t)entry->size) {
      printf("rootfs: lfs_file_write(%s) failed (wrote %ld/%u)\n",
             entry->path, (long)bw, entry->size);
      ok = false;
    }
    lfs_file_close(lfs, &fp);
    printf("rootfs: %s (%u bytes)\n", entry->path, entry->size);
  }
  return ok;
}

static int reformat(lfs_t *lfs, struct lfs_config *cfg) {
  printf("rootfs: formatting...\n");
  lfs_unmount(lfs);
  int err = lfs_format(lfs, cfg);
  if (err != LFS_ERR_OK) {
    printf("rootfs: lfs_format failed (%d)\n", err);
    return err;
  }
  err = lfs_mount(lfs, cfg);
  if (err != LFS_ERR_OK) {
    printf("rootfs: lfs_mount after format failed (%d)\n", err);
  }
  return err;
}

static void deploy_all(lfs_t *lfs, struct lfs_config *cfg) {
  if (!write_scripts(lfs)) {
    printf("rootfs: write errors, reformatting...\n");
    if (reformat(lfs, cfg) != LFS_ERR_OK) return;
    write_scripts(lfs);
  }
  write_rootfs_marker(lfs);
  printf("rootfs: deployed (%d files, hash %08lx)\n", ruby_scripts_count,
         (unsigned long)rootfs_hash);
}

void init_rootfs(void) {
  int err = littlefs_ensure_mounted();
  if (err != LFS_ERR_OK) {
    printf("rootfs: mount failed (%d)\n", err);
    return;
  }

  lfs_t *lfs = littlefs_get_lfs();
  struct lfs_config *cfg = littlefs_get_config();

  /* Reformat if trigger file exists (created by user via "touch /FORMAT") */
  struct lfs_info info;
  if (lfs_stat(lfs, FORMAT_TRIGGER_PATH, &info) == LFS_ERR_OK) {
    printf("rootfs: format trigger found, reformatting...\n");
    if (reformat(lfs, cfg) != LFS_ERR_OK) return;
    deploy_all(lfs, cfg);
    return;
  }

  /* Check rootfs hash marker */
  uint32_t stored_hash;
  if (read_rootfs_marker(lfs, &stored_hash) && stored_hash == rootfs_hash) {
    printf("rootfs: up to date (%08lx)\n", (unsigned long)rootfs_hash);
  } else {
    printf("rootfs: updating...\n");
    deploy_all(lfs, cfg);
  }
}
