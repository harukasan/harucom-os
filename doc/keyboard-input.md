# Keyboard Input

The Keyboard class converts USB HID keycodes into `Keyboard::Key` objects
in pure Ruby. A background [Task][task] polls [USB::Host][usb-host-doc]
for raw keycode state and queues results. The application reads from the
queue via `read_char`.

[usb-host-doc]: usb-host-keyboard.md
[task]: https://github.com/picoruby/picoruby

## Ruby API

### Keyboard

Class: `Keyboard`

- [Keyboard.new](#keyboardnew)
- [Keyboard#poll](#keyboardpoll)
- [Keyboard#read\_char](#keyboardread_char---keyboardkey--nil)
- [Keyboard.key](#keyboardkeyname-ctrl-shift-alt-super_key---keyboardkey)

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
  case c
  when Keyboard::ENTER
    handle_enter
  when Keyboard::CTRL_C
    handle_interrupt
  else
    buffer.put(c.to_s) if c&.printable?
  end
  DVI.wait_vsync unless c
end
```

#### Keyboard.new

Creates a new Keyboard instance with empty previous-keycode state, no
active repeat, and an empty input queue.

#### Keyboard#poll

Polls `USB::Host.keyboard_keycodes` and `USB::Host.keyboard_modifier`,
detects newly pressed keys and key repeats, converts keycodes, and
pushes results to the internal queue. Called from a background Task.

#### Keyboard#read\_char -> Keyboard::Key | nil

Pops one key input from the queue. Returns immediately (non-blocking).
Returns nil when the queue is empty.

#### Keyboard.key(name, ctrl:, shift:, alt:, super\_key:) -> Keyboard::Key

Returns a Key for the given name and modifier flags. The returned Key
can be used in `case`/`when` to match against `read_char` results.

```ruby
case c
when Keyboard.key(:f, ctrl: true)
  find
end
```

### Keyboard::Key

Class: `Keyboard::Key`

- [Key#name](#keyname---symbol)
- [Key#char](#keychar---string--nil)
- [Key#ctrl?](#keyctrl---bool)
- [Key#shift?](#keyshift---bool)
- [Key#alt?](#keyalt---bool)
- [Key#super?](#keysuper---bool)
- [Key#match?](#keymatchname-ctrl-shift-alt-super_key---bool)
- [Key#printable?](#keyprintable---bool)
- [Key#to\_s](#keyto_s---string--nil)
- [Key#to\_buffer\_input](#keyto_buffer_input---string--symbol--nil)
- [Key#to\_ansi](#keyto_ansi---string--nil)

A Key represents a single key event with its character value and modifier
state.

#### Key#name -> Symbol

The key's identity as a lowercase Symbol, independent of modifiers.
Letters use `:a` through `:z`. Special keys:

| Name | Key |
|---|---|
| `:enter` | Enter |
| `:escape` | Escape |
| `:bspace` | Backspace |
| `:tab` | Tab |
| `:insert` | Insert |
| `:home` | Home |
| `:end` | End |
| `:delete` | Delete |
| `:pageup` | PageUp |
| `:pagedown` | PageDown |
| `:up` | Up |
| `:down` | Down |
| `:left` | Left |
| `:right` | Right |

#### Key#char -> String | nil

The resolved printable character (`"a"`, `"A"`, `"!"`), or nil for
non-printable keys (Ctrl combinations, special keys).

#### Key#ctrl? -> bool

True if Ctrl (left or right) was held.

#### Key#shift? -> bool

True if Shift (left or right) was held.

#### Key#alt? -> bool

True if Alt (left or right) was held.

#### Key#super? -> bool

True if Super/GUI (left or right) was held.

#### Key#match?(name, ctrl:, shift:, alt:, super\_key:) -> bool

Flexible matching. Only specified parameters are checked; nil parameters
are ignored. Useful when modifier state does not matter.

```ruby
c.match?(:c, ctrl: true)  # Ctrl-C (any shift/alt/super)
c.match?(:enter)           # Enter (any modifiers)
c.match?(:a, ctrl: false)  # 'a' without Ctrl
```

#### Key#printable? -> bool

True if the key has a character value and Ctrl is not held.

#### Key#to\_s -> String | nil

Returns the printable character, or nil for non-printable keys.

#### Key#to\_buffer\_input -> String | Symbol | nil

Returns the form that `Editor::Buffer#put` accepts: a String for
printable characters, an uppercase Symbol (`:ENTER`, `:BSPACE`, etc.)
for special keys, or nil for keys Buffer does not handle.

#### Key#to\_ansi -> String | nil

Returns the ANSI escape sequence representation. Ctrl+letter returns the
corresponding ASCII control code (e.g. Ctrl-C returns `"\x03"`).
Special keys return VT100 sequences (e.g. Up returns `"\e[A"`).

### Pre-defined Constants

Common key patterns are defined as constants on the Keyboard class:

| Constant | Key |
|---|---|
| `Keyboard::CTRL_C` | Ctrl-C |
| `Keyboard::CTRL_D` | Ctrl-D |
| `Keyboard::CTRL_L` | Ctrl-L |
| `Keyboard::CTRL_Q` | Ctrl-Q |
| `Keyboard::CTRL_S` | Ctrl-S |
| `Keyboard::CTRL_Y` | Ctrl-Y |
| `Keyboard::CTRL_Z` | Ctrl-Z |
| `Keyboard::ENTER` | Enter |
| `Keyboard::ESCAPE` | Escape |
| `Keyboard::BSPACE` | Backspace |
| `Keyboard::TAB` | Tab |
| `Keyboard::DELETE` | Delete |
| `Keyboard::HOME` | Home |
| `Keyboard::END_KEY` | End |
| `Keyboard::UP` | Up |
| `Keyboard::DOWN` | Down |
| `Keyboard::LEFT` | Left |
| `Keyboard::RIGHT` | Right |
| `Keyboard::PAGEUP` | PageUp |
| `Keyboard::PAGEDOWN` | PageDown |

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
              Keyboard#poll -> Keyboard::Key -> queue
                                         |
              Keyboard#read_char -> Keyboard::Key
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

### Flyweight Cache

Key instances are cached in a class-level Hash keyed by a packed Integer
combining the HID keycode and normalized modifier flags. Left and right
modifiers are merged (e.g. Left Ctrl and Right Ctrl produce the same
cache entry). The same keycode and modifier combination always returns
the same Key instance, so repeated key events do not allocate new
objects.

### Ctrl-C Interrupt

During IRB code execution, the main task is in a polling loop checking
Sandbox state. Each iteration also calls `read_char` to check for
Ctrl-C. When detected, IRB stops the Sandbox directly:

```ruby
while @sandbox.state != :DORMANT && @sandbox.state != :SUSPENDED
  c = @keyboard.read_char
  if c == Keyboard::CTRL_C
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
   Delete, Insert, PageUp, PageDown): looked up in `KEYCODE_TO_NAME`.
2. **Ctrl + letter** (keycodes 0x04..0x1D with Ctrl modifier): Key with
   `ctrl: true` and `char: nil`.
3. **Printable characters**: looked up in `KEYCODE_TO_CHAR` and
   `KEYCODE_TO_CHAR_SHIFTED`. US keyboard layout. The tables can be
   replaced for other layouts (e.g. JIS).

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
  - [mrblib/key.rb](../mrbgems/picoruby-keyboard-input/mrblib/key.rb) -- Keyboard::Key class
  - [mrblib/keyboard.rb](../mrbgems/picoruby-keyboard-input/mrblib/keyboard.rb) -- Keyboard class (lookup tables, poll, read_char, key constants)
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
