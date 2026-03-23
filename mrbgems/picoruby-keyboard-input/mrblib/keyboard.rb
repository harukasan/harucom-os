class Keyboard
  # Modifier bitmask constants (from TinyUSB KEYBOARD_MODIFIER_*)
  MOD_LEFTCTRL   = 0x01
  MOD_LEFTSHIFT  = 0x02
  MOD_RIGHTCTRL  = 0x10
  MOD_RIGHTSHIFT = 0x20

  # Key repeat timing (frame count at 60fps)
  REPEAT_INITIAL_FRAMES  = 24  # ~400ms
  REPEAT_INTERVAL_FRAMES = 3   # ~50ms

  # HID keycode -> Symbol mapping for special keys
  KEYCODE_TO_SYMBOL = {
    0x28 => :ENTER,
    0x29 => :ESCAPE,
    0x2A => :BSPACE,
    0x2B => :TAB,
    0x49 => :INSERT,
    0x4A => :HOME,
    0x4B => :PAGEUP,
    0x4C => :DELETE,
    0x4D => :END,
    0x4E => :PAGEDOWN,
    0x4F => :RIGHT,
    0x50 => :LEFT,
    0x51 => :DOWN,
    0x52 => :UP,
  }

  # HID keycode -> character (unshifted), US layout
  # Derived from TinyUSB HID_KEYCODE_TO_ASCII
  # Index 0x00..0x67 (104 entries)
  KEYCODE_TO_CHAR = [
    #0x00  0x01  0x02  0x03
    nil,  nil,  nil,  nil,
    #0x04  0x05  0x06  0x07  0x08  0x09  0x0A  0x0B  0x0C  0x0D
    "a",  "b",  "c",  "d",  "e",  "f",  "g",  "h",  "i",  "j",
    #0x0E  0x0F  0x10  0x11  0x12  0x13  0x14  0x15  0x16  0x17
    "k",  "l",  "m",  "n",  "o",  "p",  "q",  "r",  "s",  "t",
    #0x18  0x19  0x1A  0x1B  0x1C  0x1D
    "u",  "v",  "w",  "x",  "y",  "z",
    #0x1E  0x1F  0x20  0x21  0x22  0x23  0x24  0x25  0x26  0x27
    "1",  "2",  "3",  "4",  "5",  "6",  "7",  "8",  "9",  "0",
    #0x28  0x29  0x2A  0x2B  (special keys, handled by KEYCODE_TO_SYMBOL)
    nil,  nil,  nil,  nil,
    #0x2C  0x2D  0x2E  0x2F  0x30  0x31
    " ",  "-",  "=",  "[",  "]",  "\\",
    #0x32  0x33  0x34  0x35  0x36  0x37  0x38
    "#",  ";",  "'",  "`",  ",",  ".",  "/",
    #0x39..0x53 (CapsLock, F1-F12, PrintScreen, ScrollLock, Pause,
    #            Insert, Home, PageUp, Delete, End, PageDown,
    #            Right, Left, Down, Up, NumLock)
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x39-0x40
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x41-0x48
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x49-0x50
    nil, nil, nil,                            # 0x51-0x53
    #0x54  0x55  0x56  0x57 (numpad operators)
    "/",  "*",  "-",  "+",
    #0x58 (numpad Enter, handled as :ENTER)
    nil,
    #0x59..0x63 (numpad digits)
    "1",  "2",  "3",  "4",  "5",  "6",  "7",  "8",  "9",  "0",
    #0x63 numpad dot
    ".",
    #0x64  0x65  0x66  0x67
    nil,  nil,  nil,  "=",
  ]

  # HID keycode -> character (shifted), US layout
  KEYCODE_TO_CHAR_SHIFTED = [
    #0x00  0x01  0x02  0x03
    nil,  nil,  nil,  nil,
    #0x04  0x05  0x06  0x07  0x08  0x09  0x0A  0x0B  0x0C  0x0D
    "A",  "B",  "C",  "D",  "E",  "F",  "G",  "H",  "I",  "J",
    #0x0E  0x0F  0x10  0x11  0x12  0x13  0x14  0x15  0x16  0x17
    "K",  "L",  "M",  "N",  "O",  "P",  "Q",  "R",  "S",  "T",
    #0x18  0x19  0x1A  0x1B  0x1C  0x1D
    "U",  "V",  "W",  "X",  "Y",  "Z",
    #0x1E  0x1F  0x20  0x21  0x22  0x23  0x24  0x25  0x26  0x27
    "!",  "@",  "#",  "$",  "%",  "^",  "&",  "*",  "(",  ")",
    #0x28  0x29  0x2A  0x2B  (special keys)
    nil,  nil,  nil,  nil,
    #0x2C  0x2D  0x2E  0x2F  0x30  0x31
    " ",  "_",  "+",  "{",  "}",  "|",
    #0x32  0x33  0x34  0x35  0x36  0x37  0x38
    "~",  ":",  "\"", "~",  "<",  ">",  "?",
    #0x39..0x53
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x39-0x40
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x41-0x48
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x49-0x50
    nil, nil, nil,                            # 0x51-0x53
    #0x54  0x55  0x56  0x57 (numpad operators)
    "/",  "*",  "-",  "+",
    #0x58 (numpad Enter)
    nil,
    #0x59..0x63 (numpad digits, shifted = nil per TinyUSB)
    nil,  nil,  nil,  nil,  "5",  nil,  nil,  nil,  nil,  nil,
    #0x63 numpad dot shifted
    nil,
    #0x64  0x65  0x66  0x67
    nil,  nil,  nil,  "=",
  ]

  def initialize
    @previous_keycodes = []
    @repeat_keycode = nil
    @repeat_start_frame = 0
    @repeat_last_frame = 0
    @repeat_active = false
    @queue = []
  end

  # Poll USB keyboard for new input.
  # Detects key presses, handles repeat, and queues results.
  def poll
    current_keycodes = USB::Host.keyboard_keycodes
    modifier = USB::Host.keyboard_modifier
    now = DVI.frame_count

    # Detect newly pressed keys
    new_keys = current_keycodes - @previous_keycodes
    result = nil

    if new_keys.length > 0
      new_key = new_keys[0]
      result = convert_keycode(new_key, modifier)
      # Start repeat tracking
      @repeat_keycode = new_key
      @repeat_start_frame = now
      @repeat_last_frame = now
      @repeat_active = false
    elsif @repeat_keycode
      if current_keycodes.include?(@repeat_keycode)
        elapsed = now - @repeat_start_frame
        if !@repeat_active && elapsed >= REPEAT_INITIAL_FRAMES
          @repeat_active = true
          @repeat_last_frame = now
          result = convert_keycode(@repeat_keycode, modifier)
        elsif @repeat_active && (now - @repeat_last_frame) >= REPEAT_INTERVAL_FRAMES
          @repeat_last_frame = now
          result = convert_keycode(@repeat_keycode, modifier)
        end
      else
        # Key released
        @repeat_keycode = nil
        @repeat_active = false
      end
    end

    @previous_keycodes = current_keycodes

    if result
      @queue.push(result)
    end
  end

  # Read one queued key input.
  # Returns String (printable char), Symbol (special key),
  # Integer (control code 1-26), or nil (no input).
  def read_char
    @queue.shift
  end

  private

  def convert_keycode(keycode, modifier)
    # Numpad Enter -> :ENTER
    return :ENTER if keycode == 0x58

    # Special keys
    sym = KEYCODE_TO_SYMBOL[keycode]
    return sym if sym

    is_ctrl = (modifier & (MOD_LEFTCTRL | MOD_RIGHTCTRL)) != 0
    is_shift = (modifier & (MOD_LEFTSHIFT | MOD_RIGHTSHIFT)) != 0

    # Ctrl + letter (A-Z: keycodes 0x04-0x1D) -> control code 1-26
    if is_ctrl && keycode >= 0x04 && keycode <= 0x1D
      return keycode - 0x04 + 1
    end

    # Character lookup
    if keycode < KEYCODE_TO_CHAR.length
      if is_shift
        return KEYCODE_TO_CHAR_SHIFTED[keycode]
      else
        return KEYCODE_TO_CHAR[keycode]
      end
    end

    nil
  end
end
