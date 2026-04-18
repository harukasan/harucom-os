#ifndef INIT_ROOTFS_H_
#define INIT_ROOTFS_H_

#ifdef __cplusplus
extern "C" {
#endif

/* Initialize the root filesystem on flash.
 * Mounts the LittleFS volume (auto-formats on corruption), then writes
 * Ruby scripts from firmware if the embedded hash differs from the
 * stored marker.  Leaves the volume mounted for the Ruby runtime. */
void init_rootfs(void);

#ifdef __cplusplus
}
#endif

#endif /* INIT_ROOTFS_H_ */
