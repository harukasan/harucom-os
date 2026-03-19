#ifndef USB_HOST_DEFINED_H_
#define USB_HOST_DEFINED_H_

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Initialize USB host (PIO-USB on RHPORT 1) */
void usb_host_init(void);

/* Process USB host and device stacks (tuh_task + tud_task) */
void usb_host_task(void);

/* Keyboard state */
bool usb_host_keyboard_connected(void);
uint8_t usb_host_keyboard_modifier(void);
const uint8_t *usb_host_keyboard_keycodes(void);

#ifdef __cplusplus
}
#endif

#endif /* USB_HOST_DEFINED_H_ */
