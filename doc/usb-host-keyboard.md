# USB Host Keyboard

USB keyboard input via [Pico-PIO-USB][pio-usb] host on the Harucom Board.
The keyboard state is accessible from Ruby scripts running on the mruby VM.

[pio-usb]: https://github.com/sekigon-gonnoc/Pico-PIO-USB

## Ruby API

### USB::Host

Module: `USB::Host` (provided by picoruby-usb-host mrbgem)

- [USB::Host.init](#usbhostinit)
- [USB::Host.task](#usbhosttask)
- [USB::Host.keyboard_connected?](#usbhostkeyboard_connected---bool)
- [USB::Host.keyboard_keycodes](#usbhostkeyboard_keycodes---array)
- [USB::Host.keyboard_modifier](#usbhostkeyboard_modifier---integer)

`USB::Host` provides USB host functionality for [HID][hid-spec] devices
connected via [Pico-PIO-USB][pio-usb]. It exposes keyboard state (pressed
keycodes and modifier keys) that can be polled from Ruby.

[hid-spec]: https://usb.org/document-library/hid-usage-tables-15

Use a PicoRuby background task to process USB events, and read keyboard
state from the main loop:

```ruby
Task.new(name: "usb_host") do
  loop do
    USB::Host.task
    Task.pass
  end
end

prev_keys = []
loop do
  if USB::Host.keyboard_connected?
    keys = USB::Host.keyboard_keycodes
    new_keys = keys - prev_keys      # keydown
    released = prev_keys - keys      # keyup
    prev_keys = keys
  end
end
```

### USB::Host.init

Initialize PIO-USB host and TinyUSB. Called once at startup from C
(`usb_host_init()` in `main.c`).

### USB::Host.task

Process the USB host stack (calls [TinyUSB][tinyusb]'s `tuh_task()`
internally). Runs in a PicoRuby background task so that USB callbacks are
processed cooperatively alongside the main application:

```ruby
Task.new(name: "usb_host") do
  loop do
    USB::Host.task
    Task.pass
  end
end
```

### USB::Host.keyboard_connected? -> bool

Returns whether a HID keyboard is currently mounted.

### USB::Host.keyboard_keycodes -> Array

Returns an array of currently pressed keycodes (up to 6 elements).
Values are [USB HID usage IDs][hid-spec] (e.g. 0x04 = A, 0x05 = B).
Unpressed slots are 0.

Keydown/keyup detection is done in Ruby by diffing consecutive snapshots.

### USB::Host.keyboard_modifier -> Integer

Returns the modifier bitmask.

| Bit | Modifier    |
|-----|-------------|
| 0   | Left Ctrl   |
| 1   | Left Shift  |
| 2   | Left Alt    |
| 3   | Left GUI    |
| 4   | Right Ctrl  |
| 5   | Right Shift |
| 6   | Right Alt   |
| 7   | Right GUI   |

## C API

Defined in [usb_host.h](../mrbgems/picoruby-usb-host/include/usb_host.h).

### usb_host_init

```c
void usb_host_init(void);
```

Configure PIO-USB, enable VBUS power, and initialize [TinyUSB][tinyusb]
host. Called once at startup before the mruby VM starts.

### usb_host_task

```c
void usb_host_task(void);
```

Process the USB host stack. Calls `tuh_task()` to dispatch enumeration and
HID report callbacks.

### usb_host_keyboard_connected

```c
bool usb_host_keyboard_connected(void);
```

Returns `true` if a HID keyboard is currently mounted.

### usb_host_keyboard_keycodes

```c
const uint8_t *usb_host_keyboard_keycodes(void);
```

Returns a pointer to the 6-byte keycode array from the latest HID report.

### usb_host_keyboard_modifier

```c
uint8_t usb_host_keyboard_modifier(void);
```

Returns the modifier byte from the latest HID report.

### usb_host_last_activity_ms

```c
uint32_t usb_host_last_activity_ms(void);
```

Returns the milliseconds-since-boot timestamp of the last USB topology
activity (device mount or unmount, HID interface mount). The boot pump in
`main.c` uses it to keep pumping while a hub's chained enumerations are
still in progress.

## Hardware Configuration

### Pin Assignment

| Constant               | Pin     | Function     |
|------------------------|---------|--------------|
| HARUCOM_USBH_DP_PIN   | GPIO 8  | PIO-USB D+   |
| HARUCOM_USBH_DM_PIN   | GPIO 9  | PIO-USB D-   |
| HARUCOM_USBH_VBUS_EN_PIN | GPIO 10 | VBUS power enable |

Pin definitions are in [harucom_board.h](../include/boards/harucom_board.h).

### USB Ports

- **RHPORT 0 (native USB PHY)**: Device mode (reserved for future MSC support)
- **RHPORT 1 (PIO-USB)**: Host mode for keyboard input

## Architecture

USB host uses [Pico-PIO-USB][pio-usb] to implement a software USB host
controller on PIO, with [TinyUSB][tinyusb] as the USB stack. The native USB
PHY (RHPORT 0) is reserved for device mode (future MSC), so host mode runs
on RHPORT 1 via PIO-USB. All USB processing runs on Core 0 because Core 1
is dedicated to DVI output.

[tinyusb]: https://github.com/hathach/tinyusb

### Clock Requirement

Pico-PIO-USB derives its four PIO clock dividers (48, 96, 6, and 12 MHz
targets for full-speed and low-speed TX/RX) from `clk_sys`, so `clk_sys`
must be a multiple of 12 MHz for all dividers to be exact. A non-multiple
clock produces fractional divider jitter on the USB bit timing; direct
HID devices usually tolerate it, but hubs are repeaters with much tighter
jitter tolerance and fail to operate. The project clock is 252 MHz
(12 MHz x 21, see [dvi.md](dvi.md)).

### Hub Support

TinyUSB hub support is enabled (`CFG_TUH_HUB 1` in
[tusb_config.h](../src/tusb_config.h)), with up to `CFG_TUH_DEVICE_MAX`
(4) devices plus the hub itself. One level of hub is supported (a TinyUSB
limitation). Keyboards behind a hub enumerate like direct ones; the
`tuh_mount_cb` and `tuh_umount_cb` callbacks log every device mount,
including the hub itself, so the UART log shows how far enumeration got.

Only the first keyboard-protocol interface is tracked, and only that
interface has a report request armed. Additional keyboards on the bus are
ignored until the tracked keyboard unmounts and the other is replugged.

### Boot Enumeration Pump

`main.c` pumps `usb_host_task()` before starting the mruby VM, because
enumeration callbacks racing a literal-heavy bootstrap can corrupt the
mruby heap. A hub chains enumerations (hub, port power, debounce, port
reset, downstream devices), so the pump exits on quiet time since the
last mount or unmount activity (reported by `usb_host_last_activity_ms`)
rather than a fixed deadline: 200 ms of quiet once a keyboard is mounted,
700 ms otherwise, with a 4 s hard cap. A boot with nothing attached exits
after 700 ms.

### Resource Allocation

PIO-USB shares Core 0 and the DMA controller with other subsystems. The
following resources are assigned to avoid conflicts:

- **DMA channel 2**: PIO-USB USB transactions (channels 0, 1 are used by DVI)
- **Core 0**: Runs both tuh_task() and tud_task()
- **Core 1**: Reserved for DVI output
- **stdio**: UART only (pico_enable_stdio_usb is disabled because TinyUSB
  host mode requires a project-level [tusb_config.h](../src/tusb_config.h))

### IRQ Priority

PIO-USB SOF timer (TIMER0_IRQ_2) fires every 1 ms to send Start-of-Frame
packets and process USB transactions. These transactions bit-bang on PIO
state machines with strict timing requirements. If a higher-priority IRQ
preempts the SOF handler mid-transaction, PIO timing breaks and the host
hangs.

To prevent this, the SOF timer runs at the highest priority (0x00), and
other Core 0 IRQs are assigned lower priorities:

| IRQ              | Priority | Purpose                      |
|------------------|----------|------------------------------|
| TIMER0_IRQ_2     | 0x00     | PIO-USB SOF timer            |
| TIMER0_IRQ_0     | 0x20     | mruby task scheduler tick    |
| DMA_IRQ_1        | 0x40     | DVI scanline render (Core 1) |

### HID Report Processing

[TinyUSB][tinyusb] dispatches events through five callbacks in
[ports/rp2350/usb_host.c](../mrbgems/picoruby-usb-host/ports/rp2350/usb_host.c).
Each callback updates static state that the Ruby API reads directly (no
event queue or buffering), and every mount or unmount stamps the activity
time used by the boot pump:

- `tuh_mount_cb` / `tuh_umount_cb`: Log every device attach and detach
  (hubs included) and stamp activity
- `tuh_hid_mount_cb`: Records device address and instance and requests
  the first HID report when a keyboard (HID_ITF_PROTOCOL_KEYBOARD) is
  enumerated and no keyboard is tracked yet
- `tuh_hid_report_received_cb`: Ignores reports from anything but the
  tracked keyboard interface, copies the modifier byte and 6-byte keycode
  array into static state, then requests the next report
- `tuh_hid_umount_cb`: Clears the connection flag and zeroes keyboard
  state when the tracked keyboard detaches

### Debugging

`USB_LOG=2 rake` builds a firmware with TinyUSB host logging
(`CFG_TUSB_DEBUG=2`) on the UART console (115200 baud). Toggling the flag
only reconfigures the CMake build; no `rake distclean` is needed. The
always-on `tuh_mount_cb` printfs show device mounts without a debug
build.

Hub enumeration triage from the log:

1. No `USB device mounted (dev_addr=1)` line: the hub itself never
   enumerates. Attach, reset, or bit-level timing problem.
2. Hub mounted but silent afterwards: the hub's interrupt status
   endpoint is not delivering port change events.
3. Port change logged but no downstream device appears: the downstream
   port reset or the follow-up enumeration fails.
4. Downstream keyboard mounts but keys are dead: host-side HID tracking
   problem; check which dev_addr and instance the reports come from.

### File Layout

- [lib/Pico-PIO-USB/](../lib/Pico-PIO-USB/) — PIO-USB library (submodule)
- [mrbgems/picoruby-usb-host/](../mrbgems/picoruby-usb-host/) — mrbgem
  - [include/usb_host.h](../mrbgems/picoruby-usb-host/include/usb_host.h) — Public header
  - [src/usb_host.c](../mrbgems/picoruby-usb-host/src/usb_host.c) — Portable API stubs
  - [src/mruby/usb_host.c](../mrbgems/picoruby-usb-host/src/mruby/usb_host.c) — Ruby bindings (USB::Host module)
  - [ports/rp2350/usb_host.c](../mrbgems/picoruby-usb-host/ports/rp2350/usb_host.c) — TinyUSB + PIO-USB implementation
- [src/tusb_config.h](../src/tusb_config.h) — Project-level TinyUSB config

## References

- [Pico-PIO-USB][pio-usb]: Software USB host/device controller using PIO
- [TinyUSB][tinyusb]: USB host/device stack (bundled with pico-sdk)
- [USB HID Usage Tables][hid-spec]: Keyboard usage IDs and modifier definitions
