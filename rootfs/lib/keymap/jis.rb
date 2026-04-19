# JIS (Japanese) keyboard layout.
# HID keycode (0x00..0x8B) indexed tables. Differences from US are in the
# symbol row, the right-side bracket/backslash keys, and JIS-specific keys
# 0x87 (ろ/\_) and 0x89 (¥|). 0x35 (半角/全角), 0x88 (カタカナ/ひらがな),
# 0x8A (変換), 0x8B (無変換) are IME/toggle keys and produce no character.

Keyboard.set_keymap(
  normal: [
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
    #0x28  0x29  0x2A  0x2B  (special keys)
    nil,  nil,  nil,  nil,
    #0x2C  0x2D  0x2E  0x2F  0x30  0x31
    " ",  "-",  "^",  "@",  "[",  "]",
    #0x32 (non-US # on JIS: unused)
    nil,
    #0x33  0x34  0x35  0x36  0x37  0x38
    ";",  ":",  nil,  ",",  ".",  "/",
    #0x39..0x53
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x39-0x40
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x41-0x48
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x49-0x50
    nil, nil, nil,                            # 0x51-0x53
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
    #0x68..0x86 (F13-F24 and reserved range, unused)
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x68-0x6F
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x70-0x77
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x78-0x7F
    nil, nil, nil, nil, nil, nil, nil,       # 0x80-0x86
    #0x87  International 1 (ろ / \_)
    "\\",
    #0x88  International 2 (カタカナ/ひらがな)
    nil,
    #0x89  International 3 (¥ / |)
    "\\",
    #0x8A  International 4 (変換)
    nil,
    #0x8B  International 5 (無変換)
    nil,
  ],

  shifted: [
    #0x00  0x01  0x02  0x03
    nil,  nil,  nil,  nil,
    #0x04  0x05  0x06  0x07  0x08  0x09  0x0A  0x0B  0x0C  0x0D
    "A",  "B",  "C",  "D",  "E",  "F",  "G",  "H",  "I",  "J",
    #0x0E  0x0F  0x10  0x11  0x12  0x13  0x14  0x15  0x16  0x17
    "K",  "L",  "M",  "N",  "O",  "P",  "Q",  "R",  "S",  "T",
    #0x18  0x19  0x1A  0x1B  0x1C  0x1D
    "U",  "V",  "W",  "X",  "Y",  "Z",
    #0x1E  0x1F  0x20  0x21  0x22  0x23  0x24  0x25  0x26  0x27
    "!",  "\"", "#",  "$",  "%",  "&",  "'",  "(",  ")",  nil,
    #0x28  0x29  0x2A  0x2B  (special keys)
    nil,  nil,  nil,  nil,
    #0x2C  0x2D  0x2E  0x2F  0x30  0x31
    " ",  "=",  "~",  "`",  "{",  "}",
    #0x32 (non-US # on JIS: unused)
    nil,
    #0x33  0x34  0x35  0x36  0x37  0x38
    "+",  "*",  nil,  "<",  ">",  "?",
    #0x39..0x53
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x39-0x40
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x41-0x48
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x49-0x50
    nil, nil, nil,                            # 0x51-0x53
    #0x54  0x55  0x56  0x57 (numpad operators)
    "/",  "*",  "-",  "+",
    #0x58 (numpad Enter)
    nil,
    #0x59..0x62 (numpad digits, shifted = nil per TinyUSB)
    nil,  nil,  nil,  nil,  "5",  nil,  nil,  nil,  nil,  nil,
    #0x63 numpad dot shifted
    nil,
    #0x64  0x65  0x66  0x67
    nil,  nil,  nil,  "=",
    #0x68..0x86 (F13-F24 and reserved range, unused)
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x68-0x6F
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x70-0x77
    nil, nil, nil, nil, nil, nil, nil, nil,  # 0x78-0x7F
    nil, nil, nil, nil, nil, nil, nil,       # 0x80-0x86
    #0x87  International 1 (ろ / \_)
    "_",
    #0x88  International 2
    nil,
    #0x89  International 3 (¥ / |)
    "|",
    #0x8A  International 4
    nil,
    #0x8B  International 5
    nil,
  ]
)
