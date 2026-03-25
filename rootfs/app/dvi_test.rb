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
    DVI::Graphics.commit
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

G = DVI::Graphics
W = G::WIDTH
H = G::HEIGHT

def show_step_gfx(title, step, kb)
  G.fill_rect(0, H - 10, W, 10, 0x00)
  G.draw_text(0, H - 8, "[" + step.to_s + "] " + title, 0xFF)
  wait_key(kb)
end

# === Graphics Mode Tests ===

DVI.set_mode(DVI::GRAPHICS_MODE)

# Step 1: fill + draw_text (8x8 font)
G.fill(0x00)
G.draw_text(10, 10, "Hello, Harucom!", 0xFF)
G.draw_text(10, 20, "DVI::Graphics 8x8 font", 0xE0)
G.draw_text(10, 30, "ABCDEFGHIJKLMNOPQRSTUVWXYZ", 0x1C)
G.draw_text(10, 40, "0123456789 !@#$%^&*()", 0xFC)
show_step_gfx("draw_text 8x8", 1, keyboard)

# Step 2+: font showcase (paginated)
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
  [G::FONT_HELVETICA_14,      "Helvetica 14",      0xFF],
  [G::FONT_HELVETICA_BOLD_14, "Helvetica Bold 14", 0xFF],
  [G::FONT_TIMES_14,          "Times 14",          0xFF],
  [G::FONT_TIMES_BOLD_14,     "Times Bold 14",     0xFF],
  [G::FONT_NEW_CENTURY_14,      "New Century 14",      0xFF],
  [G::FONT_NEW_CENTURY_BOLD_14, "New Century Bold 14", 0xFF],
  [G::FONT_HELVETICA_18,      "Helvetica 18",      0xFF],
  [G::FONT_HELVETICA_BOLD_18, "Helvetica Bold 18", 0xFF],
  [G::FONT_TIMES_18,          "Times 18",          0xFF],
  [G::FONT_TIMES_BOLD_18,     "Times Bold 18",     0xFF],
  [G::FONT_NEW_CENTURY_18,      "New Century 18",      0xFF],
  [G::FONT_NEW_CENTURY_BOLD_18, "New Century Bold 18", 0xFF],
  [G::FONT_HELVETICA_24,      "Helvetica 24",      0xFF],
  [G::FONT_HELVETICA_BOLD_24, "Helvetica Bold 24", 0xFF],
  [G::FONT_TIMES_24,          "Times 24",          0xFF],
  [G::FONT_TIMES_BOLD_24,     "Times Bold 24",     0xFF],
  [G::FONT_NEW_CENTURY_24,      "New Century 24",      0xFF],
  [G::FONT_NEW_CENTURY_BOLD_24, "New Century Bold 24", 0xFF],
]
page_size = 5
page = 0
while page * page_size < all_fonts.length
  G.fill(0x00)
  y = 4
  i = page * page_size
  while i < all_fonts.length && i < (page + 1) * page_size
    font, label, color = all_fonts[i]
    G.draw_text(4, y, label, 0x8F, font)
    G.draw_text(4, y + 14, "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789", color, font)
    G.draw_text(4, y + 46, "abcdefghijklmnopqrstuvwxyz !@#$%^&*()", color, font)
    y += 84
    i += 1
  end
  total_pages = (all_fonts.length + page_size - 1) / page_size
  show_step_gfx("fonts #{page + 1}/#{total_pages}", page + 2, keyboard)
  page += 1
end

step = page + 2

# Japanese text rendering
J12 = G::FONT_MPLUS_J12
G.fill(0x00)
G.draw_text(4, 4, "M+ 12px Japanese", 0x8F, G::FONT_MPLUS_12, J12)
G.draw_text(4, 20, "こんにちは世界！", 0xFF, G::FONT_MPLUS_12, J12)
G.draw_text(4, 36, "Harucom OSへようこそ", 0xE0, G::FONT_MPLUS_12, J12)
G.draw_text(4, 52, "漢字・ひらがな・カタカナ", 0x1C, G::FONT_MPLUS_12, J12)
G.draw_text(4, 68, "ABCDEFG abcdefg 0123456789", 0xFC, G::FONT_MPLUS_12, J12)
G.draw_text(4, 88, "混在テスト: Ruby on Harucom!", 0xFF, G::FONT_MPLUS_12, J12)
G.draw_text(4, 108, "記号テスト: ★●▲■◆○△□◇", 0xE3, G::FONT_MPLUS_12, J12)
show_step_gfx("M+ Japanese", step, keyboard)
step += 1

# DenkiChip Japanese text rendering
DJ = G::FONT_DENKICHIP_J
G.fill(0x00)
G.draw_text(4, 4, "DenkiChip Japanese", 0x8F, G::FONT_DENKICHIP, DJ)
G.draw_text(4, 20, "こんにちは世界！", 0xFF, G::FONT_DENKICHIP, DJ)
G.draw_text(4, 36, "Harucom OSへようこそ", 0xE0, G::FONT_DENKICHIP, DJ)
G.draw_text(4, 52, "漢字・ひらがな・カタカナ", 0x1C, G::FONT_DENKICHIP, DJ)
G.draw_text(4, 68, "ABCDEFG abcdefg 0123456789", 0xFC, G::FONT_DENKICHIP, DJ)
G.draw_text(4, 88, "混在テスト: Ruby on Harucom!", 0xFF, G::FONT_DENKICHIP, DJ)
show_step_gfx("DenkiChip JP", step, keyboard)
step += 1

# draw_line
cx = W / 2
cy = H / 2
G.fill(0x00)
G.draw_line(0, 0, W - 1, H - 1, 0xE0)
G.draw_line(W - 1, 0, 0, H - 1, 0x1C)
G.draw_line(cx, 0, cx, H - 1, 0x03)
G.draw_line(0, cy, W - 1, cy, 0x03)
16.times do |i|
  angle = i * 3.14159 * 2 / 16
  ex = cx + (200 * Math.cos(angle)).to_i
  ey = cy + (160 * Math.sin(angle)).to_i
  G.draw_line(cx, cy, ex, ey, 0xFF)
end
show_step_gfx("draw_line", step, keyboard)
step += 1

# fill_rect + draw_text overlay
G.fill(0x00)
G.fill_rect(40, 40, 240, 160, 0xE0)
G.fill_rect(200, 120, 240, 160, 0x1C)
G.fill_rect(360, 200, 240, 160, 0x03)
G.draw_text(60, 100, "RED", 0xFF)
G.draw_text(220, 180, "GREEN", 0xFF)
G.draw_text(380, 260, "BLUE", 0xFF)
show_step_gfx("fill_rect + overlay", step, keyboard)
step += 1

# set_pixel pattern
G.fill(0x00)
gh = H * 2 / 3
gw = W * 2 / 3
ox = (W - gw) / 2
oy = (H - gh) / 2
gh.times do |y|
  gw.times do |x|
    r = (x * 7 / gw) << 5
    g = (y * 7 / gh) << 2
    b = ((x + y) * 3 / (gw + gh))
    G.set_pixel(x + ox, y + oy, r | g | b)
  end
end
G.draw_text(ox + 10, oy - 10, "RGB332 gradient", 0xFF)
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
