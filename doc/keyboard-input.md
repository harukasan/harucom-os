# Keyboard Input

The Keyboard class converts USB HID keycodes into characters, symbols,
and control codes in pure Ruby. It polls [USB::Host][usb-host-doc] for
raw keycode state and provides a single `read_char` method for the
application layer.

[usb-host-doc]: usb-host-keyboard.md

## Ruby API

Class: `Keyboard`

- [Keyboard.new](#keyboardnew)
- [Keyboard#read\_char](#keyboardread_char---string--symbol--integer--nil)

A Keyboard instance tracks per-key state for press detection and repeat.
The application creates one instance and calls `read_char` each iteration
of its main loop.

```ruby
keyboard = Keyboard.new
loop do
  c = keyboard.read_char
  # c is String, Symbol, Integer, or nil
  DVI.wait_vsync
end
```

### Keyboard.new

Creates a new Keyboard instance with empty previous-keycode state and no
active repeat.

### Keyboard#read\_char -> String | Symbol | Integer | nil

Reads one key input. Returns immediately (non-blocking).

| Type    | Meaning              | Examples                                    |
|---------|----------------------|---------------------------------------------|
| String  | Printable character  | `"a"`, `"A"`, `"!"`, `" "`                 |
| Symbol  | Special key          | `:ENTER`, `:BSPACE`, `:UP`, `:DOWN`, `:LEFT`, `:RIGHT`, `:HOME`, `:END`, `:DELETE`, `:TAB`, `:ESCAPE` |
| Integer | Control code (Ctrl+letter) | 1 (Ctrl-A), 3 (Ctrl-C), 19 (Ctrl-S)   |
| nil     | No input             |                                             |

String and Symbol values can be passed directly to `Editor::Buffer#put`.
Integer control codes are handled by the caller (e.g. IRB or editor)
before reaching Buffer.

## Architecture

### Data Flow

The C layer receives HID keyboard reports via [TinyUSB][tinyusb]
callbacks and stores raw state in static variables (see
[USB Host Keyboard][usb-host-doc] for details). The Keyboard class polls
this state through `USB::Host.keyboard_keycodes` and
`USB::Host.keyboard_modifier`.

[tinyusb]: https://github.com/hathach/tinyusb

```
USB Keyboard -> TinyUSB callback -> keycode state (C)
                                         |
              USB::Host.keyboard_keycodes (Ruby poll)
                                         |
              Keyboard#read_char -> String / Symbol / Integer / nil
```

HAL stdin/stdout remain UART-only for debug. Keyboard input does not
flow through `hal_stdin_push()`.

### Key Press Detection

Each call to `read_char` compares the current keycode array against the
previous one using `Array#-`. Keys present in the current report but
absent from the previous report are newly pressed. The first new key
found is converted and returned.

### Keycode Conversion

Conversion follows this priority:

1. **Special keys** (Enter, Escape, Backspace, Tab, arrows, Home, End,
   Delete, Insert, PageUp, PageDown): looked up in a Hash
   (`KEYCODE_TO_SYMBOL`), returned as Symbol.
2. **Ctrl + letter** (keycodes 0x04..0x1D with Ctrl modifier): returned
   as Integer 1..26.
3. **Printable characters**: looked up in two Array tables
   (`KEYCODE_TO_CHAR`, `KEYCODE_TO_CHAR_SHIFTED`), derived from
   TinyUSB's `HID_KEYCODE_TO_ASCII`. US keyboard layout. The tables
   can be replaced for other layouts (e.g. JIS).

### Key Repeat

USB HID boot protocol sends key-state snapshots, not repeat events.
Software repeat is implemented in Keyboard:

- Timing source: `DVI.frame_count` (60 fps, ~16.67 ms per frame)
- Initial delay: 24 frames (~400 ms)
- Repeat interval: 3 frames (~50 ms)
- Only the most recently pressed key is tracked for repeat
- A new key press resets repeat tracking

### Threading

`USB::Host.task` runs in a background [mruby Task][task] (cooperative
scheduling). `Keyboard#read_char` is called from the main loop on Core 0.
No mutex or interrupt-disable is needed because all Ruby code runs on a
single core.

[task]: https://github.com/picoruby/picoruby

## File Layout

- [mrbgems/picoruby-keyboard-input/](../mrbgems/picoruby-keyboard-input/)
  - [mrblib/keyboard.rb](../mrbgems/picoruby-keyboard-input/mrblib/keyboard.rb) -- Keyboard class (lookup tables, read_char, repeat logic)
  - [mrbgem.rake](../mrbgems/picoruby-keyboard-input/mrbgem.rake) -- Gem specification

## References

- [USB Host Keyboard][usb-host-doc]: Low-level USB host, HID callbacks,
  and `USB::Host` Ruby API
- [TinyUSB HID header][tinyusb-hid]: `HID_KEYCODE_TO_ASCII` macro and
  HID key constants
- [Editor::Buffer][editor-buffer]: Target interface for key input
  (String and Symbol via `put` method)

[tinyusb-hid]: ../lib/pico-sdk/lib/tinyusb/src/class/hid/hid.h
[editor-buffer]: ../lib/picoruby/mrbgems/picoruby-editor/mrblib/buffer.rb
