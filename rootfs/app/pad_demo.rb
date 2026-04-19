# pad_demo: Board::Pad button input demo
#
# Displays real-time button state for both ADC pads.
# Press Ctrl-C or Escape to quit.

require "board/pad"

keyboard = $keyboard

left_pad  = Board::Pad.new(Board::PAD0_PIN)
right_pad = Board::Pad.new(Board::PAD1_PIN)

DVI.set_mode(DVI::TEXT_MODE)
DVI::Text.clear(0xF0)
DVI::Text.put_string(0, 0, "Board::Pad Demo", 0x1F)
DVI::Text.put_string(0, 1, "Press buttons on ADC pads. Esc to quit.", 0xF0)

LABEL_ATTR = 0xF0
ON_ATTR    = 0xF4  # white text, red background
OFF_ATTR   = 0xF0  # white text, black background

def draw_pad(pad, label, base_col, base_row)
  raw_str = "#{label}  raw: #{pad.raw.to_s.rjust(4)}"
  DVI::Text.put_string(base_col, base_row, raw_str, LABEL_ATTR)

  center = base_col + 8
  left_col = base_col
  right_col = base_col + 16

  # UP
  on = pad.up?
  attr = on ? ON_ATTR : OFF_ATTR
  DVI::Text.put_string(center, base_row + 2, on ? "[ UP  ]" : "[     ]", attr)

  # LEFT and RIGHT
  on = pad.left?
  attr = on ? ON_ATTR : OFF_ATTR
  DVI::Text.put_string(left_col, base_row + 4, on ? "[LEFT ]" : "[     ]", attr)
  on = pad.right?
  attr = on ? ON_ATTR : OFF_ATTR
  DVI::Text.put_string(right_col, base_row + 4, on ? "[RIGHT]" : "[     ]", attr)

  # DOWN
  on = pad.down?
  attr = on ? ON_ATTR : OFF_ATTR
  DVI::Text.put_string(center, base_row + 6, on ? "[DOWN ]" : "[     ]", attr)
end

loop do
  # Check for quit
  key = keyboard.read_char
  if key == Keyboard::CTRL_C || key == Keyboard::ESCAPE
    DVI::Text.clear(0xF0)
    DVI::Text.commit
    return
  end

  left_pad.read
  right_pad.read

  draw_pad(left_pad, "PAD0", 0, 4)
  draw_pad(right_pad, "PAD1", 40, 4)

  DVI::Text.commit
end
