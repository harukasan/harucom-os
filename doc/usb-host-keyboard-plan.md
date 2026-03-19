# USB Host Keyboard Implementation Plan

## Goal

Enable USB keyboard input via PIO-USB host on the Harucom Board, controllable
from Ruby scripts running on the mruby VM.

## Hardware Configuration

- **RHPORT 0 (native USB PHY)**: Device mode (future MSC support via tud_task)
- **RHPORT 1 (PIO-USB)**: Host mode for keyboard input
- **GPIO pins**: D+ = GPIO 8, D- = GPIO 9, VBUS enable = GPIO 10
  (defined in harucom_board.h)
- **stdio**: UART only (pico_enable_stdio_usb disabled)

Both tud_task() and tuh_task() run on Core 0. Core 1 is reserved for DVI output.

## Ruby API

Module: `USB::Host`

```ruby
USB::Host.init                  # Initialize PIO-USB host and TinyUSB
USB::Host.task                  # Process USB host and device stack (tuh_task + tud_task)
USB::Host.keyboard_connected?   # Whether a HID keyboard is mounted
USB::Host.keyboard_keycodes     # Array of currently pressed keycodes (up to 6)
USB::Host.keyboard_modifier     # Modifier bitmask (shift, ctrl, alt, gui)
```

Keydown/keyup detection is done in Ruby by diffing consecutive keycodes snapshots.

## Architecture

### C Layer (usb_host.c / usb_host.h)

Static state maintained in C:

```c
static bool keyboard_connected;
static hid_keyboard_report_t keyboard_report;  // modifier + keycode[6]
```

TinyUSB host callbacks:

- `tuh_hid_mount_cb`: Set keyboard_connected when HID_ITF_PROTOCOL_KEYBOARD,
  request first report via tuh_hid_receive_report
- `tuh_hid_umount_cb`: Clear keyboard_connected and zero keyboard_report
- `tuh_hid_report_received_cb`: Copy report into keyboard_report,
  re-request next report

Public C API:

```c
void usb_host_init(void);       // Configure PIO-USB, call tusb_init
void usb_host_task(void);       // Call tuh_task() + tud_task()
bool usb_host_keyboard_connected(void);
uint8_t usb_host_keyboard_modifier(void);
const uint8_t *usb_host_keyboard_keycodes(void);  // Returns pointer to keycode[6]
```

### mrbgem (picoruby-usb-host)

New mrbgem under `mrbgems/picoruby-usb-host/` with:

- `mrbgem.rake`: Gem definition (no PicoRuby dependencies for now)
- `include/usb_host.h`: Public header
- `src/usb_host.c`: mruby class/method bindings for USB::Host
- `ports/rp2350/usb_host.c`: RP2350 platform implementation (TinyUSB + PIO-USB)

### tusb_config.h

Project-level `tusb_config.h` replacing the pico-sdk default:

```c
#define CFG_TUSB_MCU            OPT_MCU_RP2040
#define CFG_TUSB_OS             OPT_OS_PICO

// Device on RHPORT 0 (native USB PHY)
#define CFG_TUSB_RHPORT0_MODE   OPT_MODE_DEVICE
#define CFG_TUD_ENABLED         0       // No device classes yet, enable later for MSC

// Host on RHPORT 1 (PIO-USB)
#define BOARD_TUH_RHPORT        1
#define CFG_TUSB_RHPORT1_MODE   OPT_MODE_HOST
#define CFG_TUH_RPI_PIO_USB    1
#define CFG_TUH_ENABLED         1

// Host class drivers
#define CFG_TUH_HID             4
#define CFG_TUH_HID_EPIN_BUFSIZE  64
#define CFG_TUH_HID_EPOUT_BUFSIZE 64
#define CFG_TUH_ENUMERATION_BUFSIZE 256
#define CFG_TUH_DEVICE_MAX      4
#define CFG_TUH_ENDPOINT_MAX    8
#define CFG_TUH_HUB             1
```

### HAL Integration

Add USB task processing to the idle hook in hal.c:

```c
void mrb_hal_task_idle_cpu(mrb_state *mrb) {
    usb_host_task();   // tuh_task() + tud_task()
    asm volatile("wfe\n" "nop\n" "sev\n" : : : "memory");
}
```

### Build Changes

CMakeLists.txt:

- Disable `pico_enable_stdio_usb` (UART only)
- Link `tinyusb_host`, `tinyusb_pico_pio_usb`
- Add USB host source files and include paths
- Add `BOARD_TUH_RHPORT=1` compile definition

build_config/harucom-os-pico2.rb:

- Add `conf.gem` for `picoruby-usb-host`

## File Layout

```
mrbgems/picoruby-usb-host/
  mrbgem.rake
  include/usb_host.h
  src/usb_host.c              # mruby bindings
  ports/rp2350/usb_host.c     # TinyUSB + PIO-USB implementation
src/tusb_config.h             # Project-level TinyUSB config
```

## Implementation Order

1. Create mrbgem skeleton (mrbgem.rake, headers, source stubs)
2. Implement C platform layer (PIO-USB init, callbacks, state)
3. Implement mruby bindings (USB::Host module methods)
4. Add tusb_config.h
5. Update CMakeLists.txt (link TinyUSB host, add sources, disable stdio_usb)
6. Update build_config to include the new gem
7. Integrate usb_host_task() into HAL idle loop
8. Build and test
