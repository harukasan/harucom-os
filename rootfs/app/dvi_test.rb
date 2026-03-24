# DVI Graphics + Text API test
#
# Exercises: Graphics primitives (draw_text, draw_line, fill, fill_rect),
#            Text mode (clear, put_string, commit, scroll),
#            Mode switching, Machine API
#
# Each step waits for a keypress so you can visually verify the result.

keyboard = $keyboard

def wait_key(kb)
  loop do
    c = kb.read_char
    return c if c
    DVI.wait_vsync
  end
end

def show_step_text(title, detail, step, kb)
  DVI::Text.clear_line(0, 0x1F)
  DVI::Text.put_string(0, 0, title, 0x1F)
  DVI::Text.clear_line(36, 0x8F)
  s = "[" + step.to_s + "] Press any key"
  DVI::Text.put_string(0, 36, s, 0x8F)
  if detail
    DVI::Text.put_string(0, 35, detail, 0xF0)
  end
  DVI::Text.commit
  wait_key(kb)
end

def show_step_gfx(title, step, kb)
  DVI::Graphics.fill_rect(0, 230, 320, 10, 0x00)
  DVI::Graphics.draw_text(0, 232, "[" + step.to_s + "] " + title, 0xFF)
  wait_key(kb)
end

# === Graphics Mode Tests ===

DVI.set_mode(DVI::GRAPHICS_MODE)

# Step 1: fill + draw_text (8x8 font)
DVI::Graphics.fill(0x00)
DVI::Graphics.draw_text(10, 10, "Hello, Harucom!", 0xFF)
DVI::Graphics.draw_text(10, 20, "DVI::Graphics 8x8 font", 0xE0)
DVI::Graphics.draw_text(10, 30, "ABCDEFGHIJKLMNOPQRSTUVWXYZ", 0x1C)
DVI::Graphics.draw_text(10, 40, "0123456789 !@#$%^&*()", 0xFC)
show_step_gfx("draw_text 8x8", 1, keyboard)

# Step 2-3: font showcase (2 pages)
G = DVI::Graphics
all_fonts = [
  [G::FONT_8X8,          "8x8",          0xE0],
  [G::FONT_MPLUS_12,     "M+ 12px",      0x1C],
  [G::FONT_FIXED_4X6,    "Fixed 4x6",    0xFC],
  [G::FONT_FIXED_5X7,    "Fixed 5x7",    0x03],
  [G::FONT_FIXED_6X13,   "Fixed 6x13",   0xFF],
  [G::FONT_SPLEEN_5X8,   "Spleen 5x8",   0xE3],
  [G::FONT_SPLEEN_8X16,  "Spleen 8x16",  0x1F],
  [G::FONT_SPLEEN_12X24, "Spleen 12x24", 0xE0],
  [G::FONT_DENKICHIP,    "DenkiChip",    0xFC],
]
page_size = 5
page = 0
while page * page_size < all_fonts.length
  DVI::Graphics.fill(0x00)
  y = 4
  i = page * page_size
  while i < all_fonts.length && i < (page + 1) * page_size
    font, label, color = all_fonts[i]
    DVI::Graphics.draw_text(4, y, label, 0x8F, font)
    DVI::Graphics.draw_text(4, y + 10, "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789", color, font)
    DVI::Graphics.draw_text(4, y + 20, "abcdefghijklmnopqrstuvwxyz !@#$%^&*()", color, font)
    y += 42
    i += 1
  end
  total_pages = (all_fonts.length + page_size - 1) / page_size
  show_step_gfx("fonts #{page + 1}/#{total_pages}", page + 2, keyboard)
  page += 1
end

step = page + 1

# draw_line
DVI::Graphics.fill(0x00)
DVI::Graphics.draw_line(0, 0, 319, 239, 0xE0)
DVI::Graphics.draw_line(319, 0, 0, 239, 0x1C)
DVI::Graphics.draw_line(160, 0, 160, 239, 0x03)
DVI::Graphics.draw_line(0, 120, 319, 120, 0x03)
16.times do |i|
  angle = i * 3.14159 * 2 / 16
  ex = 160 + (100 * Math.cos(angle)).to_i
  ey = 120 + (80 * Math.sin(angle)).to_i
  DVI::Graphics.draw_line(160, 120, ex, ey, 0xFF)
end
show_step_gfx("draw_line", step, keyboard)
step += 1

# fill_rect + draw_text overlay
DVI::Graphics.fill(0x00)
DVI::Graphics.fill_rect(20, 20, 120, 80, 0xE0)
DVI::Graphics.fill_rect(100, 60, 120, 80, 0x1C)
DVI::Graphics.fill_rect(180, 100, 120, 80, 0x03)
DVI::Graphics.draw_text(30, 50, "RED", 0xFF)
DVI::Graphics.draw_text(110, 90, "GREEN", 0xFF)
DVI::Graphics.draw_text(190, 130, "BLUE", 0xFF)
show_step_gfx("fill_rect + overlay", step, keyboard)
step += 1

# set_pixel pattern
DVI::Graphics.fill(0x00)
120.times do |y|
  160.times do |x|
    r = (x * 7 / 160) << 5
    g = (y * 7 / 120) << 2
    b = ((x + y) * 3 / 280)
    DVI::Graphics.set_pixel(x + 80, y + 60, r | g | b)
  end
end
DVI::Graphics.draw_text(100, 50, "RGB332 gradient", 0xFF)
show_step_gfx("set_pixel gradient", step, keyboard)

# === Text Mode Tests ===

DVI.set_mode(DVI::TEXT_MODE)

# Step 6: text clear + put_string
DVI::Text.clear(0xF0)
37.times do |r|
  DVI::Text.put_string(0, r, "Row " + r.to_s, 0xF0)
end
show_step_text("6: clear + put_string", "All 37 rows filled", 6, keyboard)

# Step 7: scroll_up
DVI::Text.clear(0xF0)
37.times do |r|
  DVI::Text.put_string(0, r, "Line " + r.to_s, 0xF0)
end
DVI::Text.commit
wait_key(keyboard)
DVI::Text.scroll_up(5, 0xF0)
show_step_text("7: scroll_up(5)", "Lines shifted up by 5", 7, keyboard)

# Step 8: scroll_down
DVI::Text.scroll_down(3, 0xF0)
show_step_text("8: scroll_down(3)", "Lines shifted down by 3", 8, keyboard)

# Step 9: Machine info
DVI::Text.clear(0xF0)
t1 = Machine.uptime_us
sleep_ms 100
t2 = Machine.uptime_us
elapsed = t2 - t1
DVI::Text.put_string(0, 2, "Elapsed: " + elapsed.to_s + " us", 0xF0)
ok = elapsed > 80000 && elapsed < 200000
DVI::Text.put_string(0, 3, ok ? "OK" : "FAIL", ok ? 0x2F : 0x4F)
id = Machine.unique_id
DVI::Text.put_string(0, 5, "ID: " + id, 0xF0)
show_step_text("9: Machine info", nil, 9, keyboard)

# Done
DVI::Text.clear(0xF0)
DVI::Text.put_string(0, 2, "All tests complete!", 0x2F)
DVI::Text.commit
