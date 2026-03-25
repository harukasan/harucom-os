# P5 drawing library test
#
# Exercises: P5 API (background, fill, stroke, no_fill, no_stroke,
#            rect, line, point, text, color, set_pixel, commit)
#
# Each step waits for a keypress so you can visually verify the result.

require "p5"

keyboard = $keyboard

def wait_key(kb)
  loop do
    c = kb.read_char
    return c if c
    DVI.wait_vsync
  end
end

p5 = P5.new
G = DVI::Graphics
W = p5.width
H = p5.height

def show_step(p5, title, step, kb)
  G.fill_rect(0, H - 10, W, 10, 0x00)
  G.draw_text(0, H - 8, "[" + step.to_s + "] " + title, 0xFF)
  wait_key(kb)
end

# Step 1: background + text
p5.background(0x00)
p5.text_font(G::FONT_MPLUS_12)
p5.text_color(0xFF)
p5.text("P5 Drawing Library Test", 10, 10)
p5.text_color(0xE0)
p5.text("Hello, Harucom!", 10, 26)
p5.text_font(G::FONT_MPLUS_12, G::FONT_MPLUS_J12)
p5.text_color(0x1C)
p5.text("P5ライブラリのテスト", 10, 42)
show_step(p5, "text + text_font", 1, keyboard)

# Step 2: fill + stroke rect
p5.background(0x00)
p5.fill(0xE0)
p5.stroke(0xFF)
p5.rect(40, 40, 200, 120)
p5.fill(0x1C)
p5.rect(160, 100, 200, 120)
p5.fill(0x03)
p5.rect(280, 160, 200, 120)
p5.text_font(G::FONT_MPLUS_12)
p5.text_color(0xFF)
p5.text("fill + stroke", 10, 10)
show_step(p5, "rect fill+stroke", 2, keyboard)

# Step 3: no_fill (stroke only)
p5.background(0x00)
p5.no_fill
p5.stroke(0xE0)
p5.rect(40, 40, 200, 120)
p5.stroke(0x1C)
p5.rect(120, 80, 200, 120)
p5.stroke(0x03)
p5.rect(200, 120, 200, 120)
p5.text_color(0xFF)
p5.text("no_fill (stroke only)", 10, 10)
show_step(p5, "rect stroke only", 3, keyboard)

# Step 4: no_stroke (fill only)
p5.background(0x00)
p5.fill(0xE0)
p5.no_stroke
p5.rect(40, 40, 200, 120)
p5.fill(0x1C)
p5.rect(160, 100, 200, 120)
p5.fill(0x03)
p5.rect(280, 160, 200, 120)
p5.text_color(0xFF)
p5.text("no_stroke (fill only)", 10, 10)
show_step(p5, "rect fill only", 4, keyboard)

# Step 5: line + point
p5.background(0x00)
p5.stroke(0xFF)
cx = W / 2
cy = H / 2
16.times do |i|
  angle = i * 3.14159 * 2 / 16
  ex = cx + (200 * Math.cos(angle)).to_i
  ey = cy + (160 * Math.sin(angle)).to_i
  p5.line(cx, cy, ex, ey)
end
p5.stroke(0xE0)
20.times do |i|
  x = cx + (210 * Math.cos(i * 3.14159 * 2 / 20)).to_i
  y = cy + (170 * Math.sin(i * 3.14159 * 2 / 20)).to_i
  p5.point(x, y)
  p5.point(x + 1, y)
  p5.point(x, y + 1)
  p5.point(x + 1, y + 1)
end
p5.text_color(0xFF)
p5.text("line + point", 10, 10)
show_step(p5, "line + point", 5, keyboard)

# Step 6: color helper + gradient
p5.background(0x00)
gh = H * 2 / 3
gw = W * 2 / 3
ox = (W - gw) / 2
oy = (H - gh) / 2
gh.times do |y|
  gw.times do |x|
    r = x * 255 / gw
    g = y * 255 / gh
    b = ((x + y) * 255 / (gw + gh))
    p5.set_pixel(x + ox, y + oy, p5.color(r, g, b))
  end
end
p5.text_color(0xFF)
p5.text("color() helper + gradient", 10, 10)
show_step(p5, "color gradient", 6, keyboard)

# Step 7: circle
p5.background(0x00)
p5.fill(0xE0)
p5.stroke(0xFF)
p5.circle(160, 200, 80)
p5.fill(0x1C)
p5.circle(320, 200, 100)
p5.no_fill
p5.stroke(0x03)
p5.circle(480, 200, 60)
p5.fill(p5.color(200, 100, 0))
p5.no_stroke
p5.circle(320, 360, 50)
p5.text_color(0xFF)
p5.text("circle: fill+stroke, no_fill, no_stroke", 10, 10)
show_step(p5, "circle", 7, keyboard)

# Step 8: triangle
p5.background(0x00)
p5.fill(0xE0)
p5.stroke(0xFF)
p5.triangle(100, 300, 250, 60, 400, 300)
p5.no_fill
p5.stroke(0x1C)
p5.triangle(300, 300, 450, 60, 600, 300)
p5.fill(0x03)
p5.no_stroke
p5.triangle(200, 440, 320, 320, 440, 440)
p5.text_color(0xFF)
p5.text("triangle: fill+stroke, stroke only, fill only", 10, 10)
show_step(p5, "triangle", 8, keyboard)

# Step 9: combined scene
p5.background(p5.color(0, 0, 64))
p5.fill(p5.color(200, 100, 0))
p5.stroke(0xFF)
p5.rect(40, 60, 260, 180)
p5.no_fill
p5.stroke(p5.color(0, 200, 0))
p5.rect(340, 60, 260, 180)
p5.fill(p5.color(200, 0, 0))
p5.no_stroke
p5.rect(40, 280, 260, 140)
p5.fill(p5.color(0, 0, 200))
p5.stroke(p5.color(255, 255, 0))
p5.rect(340, 280, 260, 140)
p5.text_font(G::FONT_SPLEEN_12X24)
p5.text_color(0xFF)
p5.text("P5 Combined Test", 10, 10)
p5.text_font(G::FONT_MPLUS_12, G::FONT_MPLUS_J12)
p5.text_color(0xFF)
p5.text("fill+stroke", 50, 140)
p5.text("stroke only", 350, 140)
p5.text("fill only", 50, 340)
p5.text("fill+stroke", 350, 340)
show_step(p5, "combined scene", 9, keyboard)

# Restore text mode
DVI.set_mode(DVI::TEXT_MODE)
DVI::Text.clear(0xF0)
DVI::Text.put_string(0, 0, "P5 test complete!", 0x2F)
DVI::Text.commit
