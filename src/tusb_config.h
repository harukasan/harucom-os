#ifndef _TUSB_CONFIG_H_
#define _TUSB_CONFIG_H_

#ifdef __cplusplus
extern "C" {
#endif

/*--------------------------------------------------------------------
 * COMMON CONFIGURATION
 *--------------------------------------------------------------------*/

#define CFG_TUSB_MCU            OPT_MCU_RP2040
#define CFG_TUSB_OS             OPT_OS_PICO

#ifndef CFG_TUSB_DEBUG
#define CFG_TUSB_DEBUG          0
#endif

/*--------------------------------------------------------------------
 * DEVICE CONFIGURATION (RHPORT 0, native USB PHY)
 *
 * Reserved for future MSC support. Device stack is disabled for now.
 *--------------------------------------------------------------------*/

#define CFG_TUSB_RHPORT0_MODE   OPT_MODE_DEVICE
#define CFG_TUD_ENABLED         0

/*--------------------------------------------------------------------
 * HOST CONFIGURATION (RHPORT 1, PIO-USB)
 *--------------------------------------------------------------------*/

#ifndef BOARD_TUH_RHPORT
#define BOARD_TUH_RHPORT        1
#endif

#define CFG_TUSB_RHPORT1_MODE   OPT_MODE_HOST
#define CFG_TUH_RPI_PIO_USB    1
#define CFG_TUH_ENABLED         1

#define CFG_TUH_MAX_SPEED       OPT_MODE_FULL_SPEED
#define CFG_TUH_ENUMERATION_BUFSIZE 256
#define CFG_TUH_HUB             1
#define CFG_TUH_DEVICE_MAX      4
#define CFG_TUH_ENDPOINT_MAX    8

/*--------------------------------------------------------------------
 * HOST CLASS DRIVERS
 *--------------------------------------------------------------------*/

#define CFG_TUH_HID             4
#define CFG_TUH_HID_EPIN_BUFSIZE  64
#define CFG_TUH_HID_EPOUT_BUFSIZE 64

#ifdef __cplusplus
}
#endif

#endif /* _TUSB_CONFIG_H_ */
