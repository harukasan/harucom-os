class Keyboard
  # Modifier bitmask constants (from TinyUSB KEYBOARD_MODIFIER_*)
  MOD_LEFTCTRL   = 0x01
  MOD_LEFTSHIFT  = 0x02
  MOD_LEFTALT    = 0x04
  MOD_LEFTGUI    = 0x08
  MOD_RIGHTCTRL  = 0x10
  MOD_RIGHTSHIFT = 0x20
  MOD_RIGHTALT   = 0x40
  MOD_RIGHTGUI   = 0x80

  # Key repeat timing (milliseconds)
  REPEAT_INITIAL_MS = 400
  REPEAT_INTERVAL_MS = 50

  # HID keycode -> name (Symbol) mapping for special keys
  KEYCODE_TO_NAME = {
    0x28 => :enter,
    0x29 => :escape,
    0x2A => :bspace,
    0x2B => :tab,
    0x49 => :insert,
    0x4A => :home,
    0x4B => :pageup,
    0x4C => :delete,
    0x4D => :end,
    0x4E => :pagedown,
    0x4F => :right,
    0x50 => :left,
    0x51 => :down,
    0x52 => :up,
  }

  # Reverse mapping: name -> HID keycode (for Keyboard.key)
  NAME_TO_KEYCODE = {}
  KEYCODE_TO_NAME.each { |code, name| NAME_TO_KEYCODE[name] = code }
  i = 0
  while i < 26
    NAME_TO_KEYCODE[(0x61 + i).chr.to_sym] = 0x04 + i
    i += 1
  end

  # HID keycode -> character tables. Populated by Keyboard.use_layout or
  # Keyboard.set_keymap at boot. The built-in tables below live in mrblib
  # (pre-compiled to bytecode) so boot does not pay for a literal-heavy
  # runtime parse, which can race with USB enumeration and corrupt the
  # mruby heap.
  @@normal_map = []
  @@shifted_map = []

  # Built-in US ANSI layout
  LAYOUT_US_NORMAL = [
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
    #0x28  0x29  0x2A  0x2B  (special keys, handled by KEYCODE_TO_NAME)
    nil,  nil,  nil,  nil,
    #0x2C  0x2D  0x2E  0x2F  0x30  0x31
    " ",  "-",  "=",  "[",  "]",  "\\",
    #0x32  0x33  0x34  0x35  0x36  0x37  0x38
    "#",  ";",  "'",  "`",  ",",  ".",  "/",
    #0x39..0x53
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil,
    #0x54  0x55  0x56  0x57 (numpad operators)
    "/",  "*",  "-",  "+",
    #0x58 (numpad Enter)
    nil,
    #0x59..0x62 (numpad digits)
    "1",  "2",  "3",  "4",  "5",  "6",  "7",  "8",  "9",  "0",
    #0x63 numpad dot
    ".",
    #0x64  0x65  0x66  0x67
    nil,  nil,  nil,  "=",
  ]

  LAYOUT_US_SHIFTED = [
    nil,  nil,  nil,  nil,
    "A",  "B",  "C",  "D",  "E",  "F",  "G",  "H",  "I",  "J",
    "K",  "L",  "M",  "N",  "O",  "P",  "Q",  "R",  "S",  "T",
    "U",  "V",  "W",  "X",  "Y",  "Z",
    "!",  "@",  "#",  "$",  "%",  "^",  "&",  "*",  "(",  ")",
    nil,  nil,  nil,  nil,
    " ",  "_",  "+",  "{",  "}",  "|",
    "~",  ":",  "\"", "~",  "<",  ">",  "?",
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil,
    "/",  "*",  "-",  "+",
    nil,
    nil,  nil,  nil,  nil,  "5",  nil,  nil,  nil,  nil,  nil,
    nil,
    nil,  nil,  nil,  "=",
  ]

  # Built-in JIS layout. Differs from US in the symbol row, bracket/backslash
  # keys, and adds JIS-specific 0x87 (ろ/\_) and 0x89 (¥/|). 0x35, 0x88, 0x8A,
  # 0x8B are IME/toggle keys with no character.
  LAYOUT_JIS_NORMAL = [
    nil,  nil,  nil,  nil,
    "a",  "b",  "c",  "d",  "e",  "f",  "g",  "h",  "i",  "j",
    "k",  "l",  "m",  "n",  "o",  "p",  "q",  "r",  "s",  "t",
    "u",  "v",  "w",  "x",  "y",  "z",
    "1",  "2",  "3",  "4",  "5",  "6",  "7",  "8",  "9",  "0",
    nil,  nil,  nil,  nil,
    " ",  "-",  "^",  "@",  "[",  "]",
    nil,
    ";",  ":",  nil,  ",",  ".",  "/",
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil,
    "/",  "*",  "-",  "+",
    nil,
    "1",  "2",  "3",  "4",  "5",  "6",  "7",  "8",  "9",  "0",
    ".",
    nil,  nil,  nil,  "=",
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil,
    "\\",  # 0x87 ろ / \_
    nil,   # 0x88 カタカナ/ひらがな
    "\\",  # 0x89 ¥ / |
    nil,   # 0x8A 変換
    nil,   # 0x8B 無変換
  ]

  LAYOUT_JIS_SHIFTED = [
    nil,  nil,  nil,  nil,
    "A",  "B",  "C",  "D",  "E",  "F",  "G",  "H",  "I",  "J",
    "K",  "L",  "M",  "N",  "O",  "P",  "Q",  "R",  "S",  "T",
    "U",  "V",  "W",  "X",  "Y",  "Z",
    "!",  "\"", "#",  "$",  "%",  "&",  "'",  "(",  ")",  nil,
    nil,  nil,  nil,  nil,
    " ",  "=",  "~",  "`",  "{",  "}",
    nil,
    "+",  "*",  nil,  "<",  ">",  "?",
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil,
    "/",  "*",  "-",  "+",
    nil,
    nil,  nil,  nil,  nil,  "5",  nil,  nil,  nil,  nil,  nil,
    nil,
    nil,  nil,  nil,  "=",
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil,
    "_",   # 0x87
    nil,
    "|",   # 0x89
    nil,
    nil,
  ]

  # Install keymap tables (layout-specific). Each argument is an Array indexed
  # by HID keycode; entries outside the array bound are treated as unmapped.
  def self.set_keymap(normal:, shifted:)
    @@normal_map = normal
    @@shifted_map = shifted
  end

  # Select a built-in layout by name. Returns true on success, false if the
  # layout is unknown (caller can fall back).
  def self.use_layout(name)
    case name.to_s
    when "us"
      set_keymap(normal: LAYOUT_US_NORMAL, shifted: LAYOUT_US_SHIFTED)
      true
    when "jis"
      set_keymap(normal: LAYOUT_JIS_NORMAL, shifted: LAYOUT_JIS_SHIFTED)
      true
    else
      false
    end
  end

  def self.normal_map;  @@normal_map;  end
  def self.shifted_map; @@shifted_map; end

  # Flyweight cache for Key instances (shared across all Keyboard instances).
  # Ensures object identity for case/when matching.
  @@key_cache = {}

  def self.key_cache
    @@key_cache
  end

  # Pack keycode and modifier flags into a single Integer for cache lookup.
  def self.pack_keycode(keycode, ctrl: false, shift: false, alt: false, super_key: false)
    (keycode << 4) | (ctrl ? 1 : 0) | (shift ? 2 : 0) | (alt ? 4 : 0) | (super_key ? 8 : 0)
  end

  # Create or look up a cached Key by name and modifiers.
  # Returns the same object that resolve_key returns for the matching
  # keycode+modifier, enabling case/when via object identity.
  def self.key(name, ctrl: false, shift: false, alt: false, super_key: false)
    keycode = NAME_TO_KEYCODE[name]
    return nil unless keycode
    packed = pack_keycode(keycode, ctrl: ctrl, shift: shift, alt: alt, super_key: super_key)
    @@key_cache[packed] ||= Key.new(name, nil, ctrl: ctrl, shift: shift, alt: alt, super_key: super_key)
  end

  # Cached key constants
  CTRL_C = key(:c, ctrl: true)
  CTRL_D = key(:d, ctrl: true)
  CTRL_L = key(:l, ctrl: true)
  CTRL_Q = key(:q, ctrl: true)
  CTRL_S = key(:s, ctrl: true)
  CTRL_Y = key(:y, ctrl: true)
  CTRL_Z = key(:z, ctrl: true)
  ENTER    = key(:enter)
  ESCAPE   = key(:escape)
  BSPACE   = key(:bspace)
  TAB      = key(:tab)
  DELETE   = key(:delete)
  HOME     = key(:home)
  END_KEY  = key(:end)
  UP       = key(:up)
  DOWN     = key(:down)
  LEFT     = key(:left)
  RIGHT    = key(:right)
  PAGEUP   = key(:pageup)
  PAGEDOWN = key(:pagedown)

  def initialize
    @previous_keycodes = []
    @repeat_keycode = nil
    @repeat_start_ms = 0
    @repeat_last_ms = 0
    @repeat_active = false
    @queue = []
    @ctrl_c_flag = false
  end

  # Check and clear the Ctrl-C flag.
  # Set by poll() when Ctrl-C is queued; does not consume the key from queue.
  def ctrl_c_pressed?
    flag = @ctrl_c_flag
    @ctrl_c_flag = false
    flag
  end

  # Poll USB keyboard for new input.
  # Detects key presses, handles repeat, and queues results.
  def poll
    current_keycodes = USB::Host.keyboard_keycodes
    modifier = USB::Host.keyboard_modifier
    now = Machine.board_millis

    # Detect newly pressed keys
    new_keys = current_keycodes - @previous_keycodes
    result = nil

    if new_keys.length > 0
      new_key = new_keys[0]
      result = resolve_key(new_key, modifier)
      # Start repeat tracking
      @repeat_keycode = new_key
      @repeat_start_ms = now
      @repeat_last_ms = now
      @repeat_active = false
    elsif @repeat_keycode
      if current_keycodes.include?(@repeat_keycode)
        elapsed = now - @repeat_start_ms
        if !@repeat_active && elapsed >= REPEAT_INITIAL_MS
          @repeat_active = true
          @repeat_last_ms = now
          result = resolve_key(@repeat_keycode, modifier)
        elsif @repeat_active && (now - @repeat_last_ms) >= REPEAT_INTERVAL_MS
          @repeat_last_ms = now
          result = resolve_key(@repeat_keycode, modifier)
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
      @ctrl_c_flag = true if result == CTRL_C
    end
  end

  # Read one queued key input.
  # Returns Keyboard::Key or nil (no input).
  def read_char
    @queue.shift
  end

  private

  # Look up or create a cached Key for the given keycode and HID modifier byte.
  def resolve_key(keycode, modifier)
    is_ctrl  = (modifier & (MOD_LEFTCTRL | MOD_RIGHTCTRL)) != 0
    is_shift = (modifier & (MOD_LEFTSHIFT | MOD_RIGHTSHIFT)) != 0
    is_alt   = (modifier & (MOD_LEFTALT | MOD_RIGHTALT)) != 0
    is_super = (modifier & (MOD_LEFTGUI | MOD_RIGHTGUI)) != 0

    packed = Keyboard.pack_keycode(keycode, ctrl: is_ctrl, shift: is_shift, alt: is_alt, super_key: is_super)
    Keyboard.key_cache[packed] ||= create_key(keycode, is_ctrl, is_shift, is_alt, is_super)
  end

  def create_key(keycode, is_ctrl, is_shift, is_alt, is_super)
    # Numpad Enter
    if keycode == 0x58
      return Key.new(:enter, nil, ctrl: is_ctrl, shift: is_shift, alt: is_alt, super_key: is_super)
    end

    # Special keys
    name = KEYCODE_TO_NAME[keycode]
    if name
      return Key.new(name, nil, ctrl: is_ctrl, shift: is_shift, alt: is_alt, super_key: is_super)
    end

    # Letter keys (A-Z: keycodes 0x04-0x1D). Name is layout-independent.
    if keycode >= 0x04 && keycode <= 0x1D
      letter_name = (0x61 + keycode - 0x04).chr.to_sym
      if is_ctrl
        return Key.new(letter_name, nil, ctrl: true, shift: is_shift, alt: is_alt, super_key: is_super)
      end
      char = is_shift ? @@shifted_map[keycode] : @@normal_map[keycode]
      return Key.new(letter_name, char, shift: is_shift, alt: is_alt, super_key: is_super)
    end

    # Other printable characters
    if keycode < @@normal_map.length
      char = is_shift ? @@shifted_map[keycode] : @@normal_map[keycode]
      return Key.new(char.to_sym, char, ctrl: is_ctrl, shift: is_shift, alt: is_alt, super_key: is_super) if char
    end

    nil
  end

end
