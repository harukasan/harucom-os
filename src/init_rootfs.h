#ifndef INIT_ROOTFS_H_
#define INIT_ROOTFS_H_

#ifdef __cplusplus
extern "C" {
#endif

/* Initialize the root filesystem on flash.
 * Formats the volume if needed, then writes Ruby scripts from firmware.
 * Must be called after DVI is running (flash writes require DVI blanking).
 * Mounts and unmounts the FatFs volume internally. */
void init_rootfs(void);

#ifdef __cplusplus
}
#endif

#endif /* INIT_ROOTFS_H_ */
