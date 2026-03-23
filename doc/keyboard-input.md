# Keyboard Input

The Keyboard class converts USB HID keycodes into characters, symbols,
and control codes in pure Ruby. A background [Task][task] polls
[USB::Host][usb-host-doc] for raw keycode state and queues results.
The application reads from the queue via `read_char`.

[usb-host-doc]: usb-host-keyboard.md
[task]: https://github.com/picoruby/picoruby

## Ruby API

Class: `Keyboard`

- [Keyboard.new](#keyboardnew)
- [Keyboard#poll](#keyboardpoll)
- [Keyboard#read\_char](#keyboardread_char---string--symbol--integer--nil)

A Keyboard instance tracks per-key state for press detection and repeat.
A background Task calls `poll` to detect key events and queue them.
The application calls `read_char` to consume queued input.

```ruby
keyboard = Keyboard.new

# Background task polls keyboard state
Task.new(name: "keyboard") do
  loop do
    keyboard.poll
    Task.pass
  end
end

# Application reads from queue
loop do
  c = keyboard.read_char
  # c is String, Symbol, Integer, or nil
  DVI.wait_vsync unless c
end
```

### Keyboard.new

Creates a new Keyboard instance with empty previous-keycode state, no
active repeat, and an empty input queue.

### Keyboard#poll

Polls `USB::Host.keyboard_keycodes` and `USB::Host.keyboard_modifier`,
detects newly pressed keys and key repeats, converts keycodes, and
pushes results to the internal queue. Called from a background Task.

### Keyboard#read\_char -> String | Symbol | Integer | nil

Pops one key input from the queue. Returns immediately (non-blocking).
Returns nil when the queue is empty.

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
              Keyboard#poll -> internal queue
                                         |
              Keyboard#read_char -> String / Symbol / Integer / nil
```

HAL stdin/stdout remain UART-only for debug. Keyboard input does not
flow through `hal_stdin_push()`.

### Background Task

Keyboard polling runs in a dedicated background Task. This decouples
input detection from the application's main loop, allowing key events
to be captured even when the main task is busy (e.g. waiting for
Sandbox execution to complete).

```ruby
Task.new(name: "keyboard") do
  loop do
    keyboard.poll
    Task.pass
  end
end
```

`Task.pass` yields to the cooperative scheduler after each poll cycle.
The scheduler runs the keyboard task whenever the main task yields
(via `sleep_ms`, `DVI.wait_vsync`, etc.).

### Input Queue

`poll` pushes detected key events to a Ruby Array used as a FIFO queue.
`read_char` pops from the front with `Array#shift`. At human typing
speeds the queue rarely exceeds a few entries, so Array performance is
sufficient.

### Ctrl-C Interrupt

During IRB code execution, the main task is in a polling loop checking
Sandbox state. Each iteration also calls `read_char` to check for
Ctrl-C (integer 3). When detected, IRB stops the Sandbox directly:

```ruby
while @sandbox.state != :DORMANT && @sandbox.state != :SUSPENDED
  if @keyboard.read_char == 3
    @sandbox.stop
    break
  end
  sleep_ms 5
end
```

During line editing, LineEditor handles Ctrl-C by clearing the input
buffer and displaying `^C`.

### Key Press Detection

Each call to `poll` compares the current keycode array against the
previous one using `Array#-`. Keys present in the current report but
absent from the previous report are newly pressed. The first new key
found is converted and queued.

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

`USB::Host.task` and `Keyboard#poll` each run in separate background
[Tasks][task] (cooperative scheduling). `Keyboard#read_char` is called
from the main task on Core 0. No mutex or interrupt-disable is needed
because all Ruby code runs on a single core under the cooperative
scheduler.

## File Layout

- [mrbgems/picoruby-keyboard-input/](../mrbgems/picoruby-keyboard-input/)
  - [mrblib/keyboard.rb](../mrbgems/picoruby-keyboard-input/mrblib/keyboard.rb) -- Keyboard class (lookup tables, poll, read_char, repeat logic)
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
