/*
 * Browser (emscripten) USB host port.
 *
 * The RP2350 port (ports/rp2350/usb_host.c) reads the keyboard report from a
 * real HID device over PIO-USB. In the browser there is no USB stack, so this
 * port holds the same keyboard state in C statics and lets JavaScript push it
 * in from DOM key events via harucom_kbd_set_state(). The shared text-input
 * pipeline (USB::Host -> Keyboard -> LineEditor) consumes it unchanged.
 *
 * The whole file is guarded by __EMSCRIPTEN__ (the wasm build is emcc), matching
 * ports/posix/dvi_wasm.c; picoruby auto-compiles ports/posix under POSIX while
 * ports/rp2350 (pico-sdk/TinyUSB) is excluded.
 */

#ifdef __EMSCRIPTEN__

#include <emscripten.h>

#include "usb_host.h"

/* Mirror of the live HID keyboard report, written by JS between Ruby polls. A
 * held key is a non-zero HID usage in slots 0..5; modifier is the HID modifier
 * bitmask. There is no concurrency (JS calls into wasm synchronously), so plain
 * statics suffice. */
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

/* Replace the whole keyboard report from JS. The browser tracks which keys are
 * held and passes the up-to-6 currently held HID usages plus the modifier byte
 * each time the set changes, so Keyboard#poll sees press, release and repeat the
 * same way it would from a hardware report. */
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
