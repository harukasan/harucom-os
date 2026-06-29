// Copyright (c) 2026 Shunsuke Michii
//
// Browser (emscripten) USB host port. Holds the keyboard state in C statics and
// lets JavaScript push it in from DOM key events via harucom_kbd_set_state().
// The shared text-input pipeline (USB::Host -> Keyboard -> LineEditor) consumes
// it unchanged.

#ifdef __EMSCRIPTEN__

#include <emscripten.h>

#include "usb_host.h"

// Mirror of the live HID keyboard report, written by JS between Ruby polls.
// Held keys are non-zero HID usages in slots 0..5; modifier is the HID modifier
// bitmask. JS calls in synchronously, so plain statics suffice.
static bool keyboard_connected_flag = true;
static uint8_t keyboard_modifier_state = 0;
static uint8_t keyboard_keycodes_state[6] = {0};

// HID modifier bits and the Delete usage for the Ctrl-Alt-Delete reboot, mirroring
// the board's tuh_hid_report_received_cb. Each mask covers the left and right key.
#define HID_MOD_CTRL (0x01 | 0x10)
#define HID_MOD_ALT  (0x04 | 0x40)
#define HID_KEY_DELETE 0x4C

void usb_host_init(void) {}

void usb_host_task(void) {}

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

// Replace the whole keyboard report from JS. The browser passes the up-to-6
// held HID usages plus the modifier each time the set changes, so Keyboard#poll
// sees press, release and repeat as it would from a hardware report.
EMSCRIPTEN_KEEPALIVE
void
harucom_kbd_set_state(uint8_t modifier, uint8_t k0, uint8_t k1, uint8_t k2,
                      uint8_t k3, uint8_t k4, uint8_t k5)
{
  keyboard_modifier_state = modifier;
  keyboard_keycodes_state[0] = k0;
  keyboard_keycodes_state[1] = k1;
  keyboard_keycodes_state[2] = k2;
  keyboard_keycodes_state[3] = k3;
  keyboard_keycodes_state[4] = k4;
  keyboard_keycodes_state[5] = k5;

  // Ctrl-Alt-Delete reboots. The board watchdog_reboots; the browser reboots by
  // reloading the page (window.__harucomReboot, set in main.js), which recreates
  // the wasm Module and reruns harucom_init from scratch.
  if ((modifier & HID_MOD_CTRL) && (modifier & HID_MOD_ALT)) {
    for (int i = 0; i < 6; i++) {
      if (keyboard_keycodes_state[i] == HID_KEY_DELETE) {
        EM_ASM({
          if (typeof window !== "undefined" && window.__harucomReboot) window.__harucomReboot();
        });
        break;
      }
    }
  }
}

#endif /* __EMSCRIPTEN__ */
