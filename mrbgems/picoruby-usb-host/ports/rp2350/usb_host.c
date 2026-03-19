/*
 * USB Host implementation for RP2350 using PIO-USB
 *
 * PIO-USB provides a software USB host controller on RHPORT 1.
 * The native USB PHY (RHPORT 0) is reserved for device mode (future MSC).
 * Both tuh_task() and tud_task() run on Core 0.
 */

#include <stdio.h>
#include <string.h>

#include "hardware/gpio.h"
#include "hardware/irq.h"
#include "pio_usb.h"
#include "tusb.h"

#include "usb_host.h"

/* Board pin definitions (from harucom_board.h) */
#ifndef HARUCOM_USBH_DP_PIN
#define HARUCOM_USBH_DP_PIN      8
#endif
#ifndef HARUCOM_USBH_VBUS_EN_PIN
#define HARUCOM_USBH_VBUS_EN_PIN 10
#endif

/* Keyboard state */
static volatile bool keyboard_connected_flag = false;
static uint8_t keyboard_dev_addr = 0;
static uint8_t keyboard_instance = 0;
static uint8_t keyboard_modifier_state = 0;
static uint8_t keyboard_keycodes_state[6] = {0};

void
usb_host_init(void)
{
  /* Enable VBUS power for USB host port */
  gpio_init(HARUCOM_USBH_VBUS_EN_PIN);
  gpio_set_dir(HARUCOM_USBH_VBUS_EN_PIN, GPIO_OUT);
  gpio_put(HARUCOM_USBH_VBUS_EN_PIN, 1);

  /* Configure PIO-USB.
   * DVI uses DMA channels 0 (cmd) and 1 (data), so PIO-USB must use
   * channel 2 or higher to avoid conflict. */
  pio_usb_configuration_t pio_cfg = PIO_USB_DEFAULT_CONFIG;
  pio_cfg.pin_dp = HARUCOM_USBH_DP_PIN;
  pio_cfg.tx_ch = 2;
  tuh_configure(BOARD_TUH_RHPORT, TUH_CFGID_RPI_PIO_USB_CONFIGURATION, &pio_cfg);

  /* Initialize TinyUSB host */
  tusb_init(BOARD_TUH_RHPORT, NULL);

  /* PIO-USB SOF timer uses TIMER_IRQ_2 via alarm_pool_create(2, 1).
   * Raise its priority so USB transactions are not preempted by other
   * Core 0 IRQs (UART, etc.), which would break USB timing. */
  irq_set_priority(TIMER0_IRQ_2, PICO_HIGHEST_IRQ_PRIORITY);

  printf("USB Host initialized (PIO-USB on GPIO %d)\n", HARUCOM_USBH_DP_PIN);
}

void
usb_host_task(void)
{
  tuh_task();
}

bool
usb_host_keyboard_connected(void)
{
  return keyboard_connected_flag;
}

uint8_t
usb_host_keyboard_modifier(void)
{
  return keyboard_modifier_state;
}

const uint8_t *
usb_host_keyboard_keycodes(void)
{
  return keyboard_keycodes_state;
}

/*--------------------------------------------------------------------
 * TinyUSB Host HID callbacks
 *--------------------------------------------------------------------*/

void
tuh_hid_mount_cb(uint8_t dev_addr, uint8_t instance,
                 uint8_t const *desc_report, uint16_t desc_len)
{
  (void)desc_report;
  (void)desc_len;

  uint8_t const itf_protocol = tuh_hid_interface_protocol(dev_addr, instance);

  if (itf_protocol == HID_ITF_PROTOCOL_KEYBOARD) {
    printf("USB keyboard connected (dev_addr=%d, instance=%d)\n",
           dev_addr, instance);
    keyboard_dev_addr = dev_addr;
    keyboard_instance = instance;
    keyboard_connected_flag = true;

    if (!tuh_hid_receive_report(dev_addr, instance)) {
      printf("USB keyboard: failed to request report\n");
    }
  }
}

void
tuh_hid_umount_cb(uint8_t dev_addr, uint8_t instance)
{
  if (dev_addr == keyboard_dev_addr && instance == keyboard_instance) {
    printf("USB keyboard disconnected\n");
    keyboard_connected_flag = false;
    keyboard_dev_addr = 0;
    keyboard_instance = 0;
    keyboard_modifier_state = 0;
    memset(keyboard_keycodes_state, 0, sizeof(keyboard_keycodes_state));
  }
}

void
tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t instance,
                            uint8_t const *report, uint16_t len)
{
  (void)len;

  uint8_t const itf_protocol = tuh_hid_interface_protocol(dev_addr, instance);

  if (itf_protocol == HID_ITF_PROTOCOL_KEYBOARD) {
    hid_keyboard_report_t const *kbd_report =
        (hid_keyboard_report_t const *)report;

    keyboard_modifier_state = kbd_report->modifier;
    memcpy(keyboard_keycodes_state, kbd_report->keycode,
           sizeof(keyboard_keycodes_state));
  }

  /* Request next report */
  tuh_hid_receive_report(dev_addr, instance);
}
