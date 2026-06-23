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
}

#endif /* __EMSCRIPTEN__ */
