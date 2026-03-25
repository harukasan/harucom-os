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
    DVI::Graphics.commit
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
p5.text_color(0xFF)
p5.text("Generating gradient... please wait", 10, 10)
p5.commit
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

# Step 9: ellipse
p5.background(0x00)
p5.fill(p5.color(100, 0, 200))
p5.stroke(0xFF)
p5.ellipse(160, 200, 120, 60)
p5.fill(p5.color(0, 200, 100))
p5.ellipse(400, 200, 60, 120)
p5.no_fill
p5.stroke(0xE0)
p5.ellipse(320, 360, 150, 40)
p5.text_color(0xFF)
p5.text("ellipse: fill+stroke, no_fill", 10, 10)
show_step(p5, "ellipse", 9, keyboard)

# Step 10: stroke_weight
p5.background(0x00)
p5.stroke(0xFF)
p5.stroke_weight(1)
p5.line(40, 80, 600, 80)
p5.stroke_weight(3)
p5.line(40, 140, 600, 140)
p5.stroke_weight(5)
p5.line(40, 220, 600, 220)
p5.stroke_weight(3)
p5.stroke(0xE0)
p5.fill(0x1C)
p5.triangle(100, 420, 250, 300, 400, 420)
p5.stroke_weight(1)
p5.text_color(0xFF)
p5.text("stroke_weight: 1, 3, 5 + thick triangle", 10, 10)
show_step(p5, "stroke_weight", 10, keyboard)

# Step 11: blend_mode ADD
p5.background(0x00)
p5.blend_mode(P5::REPLACE)
p5.fill(p5.color(200, 0, 0))
p5.no_stroke
p5.circle(240, 200, 100)
p5.fill(p5.color(0, 200, 0))
p5.circle(320, 200, 100)
p5.fill(p5.color(0, 0, 200))
p5.circle(280, 280, 100)
p5.blend_mode(P5::ADD)
p5.fill(p5.color(200, 0, 0))
p5.circle(240 + 250, 200, 100)
p5.fill(p5.color(0, 200, 0))
p5.circle(320 + 250, 200, 100)
p5.fill(p5.color(0, 0, 200))
p5.circle(280 + 250, 280, 100)
p5.blend_mode(P5::REPLACE)
p5.text_color(0xFF)
p5.text("REPLACE (left) vs ADD (right)", 10, 10)
show_step(p5, "blend ADD", 11, keyboard)

# Step 12: alpha blending
p5.background(p5.color(0, 0, 128))
p5.blend_mode(P5::REPLACE)
p5.fill(p5.color(200, 0, 0))
p5.no_stroke
p5.rect(80, 80, 240, 300)
p5.alpha(128)
p5.fill(p5.color(0, 200, 0))
p5.rect(200, 140, 240, 300)
p5.alpha(64)
p5.fill(p5.color(255, 255, 0))
p5.circle(420, 240, 100)
p5.blend_mode(P5::REPLACE)
p5.text_color(0xFF)
p5.text("alpha blending: 128, 64", 10, 10)
show_step(p5, "alpha blend", 12, keyboard)

# Step 13: translate
p5.background(0x00)
p5.reset_matrix
p5.fill(0xE0)
p5.stroke(0xFF)
p5.rect(10, 40, 80, 60)
p5.translate(200, 0)
p5.fill(0x1C)
p5.rect(10, 40, 80, 60)
p5.translate(200, 0)
p5.fill(0x03)
p5.rect(10, 40, 80, 60)
p5.reset_matrix
p5.text_color(0xFF)
p5.text("translate: 3 rects offset by 200px", 10, 10)
show_step(p5, "translate", 13, keyboard)

# Step 14: rotate
p5.background(0x00)
p5.reset_matrix
cx = W / 2
cy = H / 2
p5.fill(0xE0)
p5.stroke(0xFF)
8.times do |i|
  p5.push_matrix
  p5.translate(cx, cy)
  p5.rotate(i * 3.14159 * 2 / 8)
  p5.rect(-60, -20, 120, 40)
  p5.pop_matrix
end
p5.reset_matrix
p5.text_color(0xFF)
p5.text("rotate: 8 rotated rects", 10, 10)
show_step(p5, "rotate", 14, keyboard)

# Step 15: scale + push/pop
p5.background(0x00)
p5.reset_matrix
p5.push_matrix
p5.translate(160, 240)
p5.scale(2.0)
p5.fill(p5.color(200, 0, 0))
p5.stroke(0xFF)
p5.circle(0, 0, 40)
p5.pop_matrix
p5.push_matrix
p5.translate(320, 240)
p5.scale(1.5, 3.0)
p5.fill(p5.color(0, 200, 0))
p5.circle(0, 0, 40)
p5.pop_matrix
p5.push_matrix
p5.translate(480, 240)
p5.fill(p5.color(0, 0, 200))
p5.stroke(0xFF)
p5.circle(0, 0, 40)
p5.pop_matrix
p5.reset_matrix
p5.text_color(0xFF)
p5.text("scale: 2x circle, 1.5x3 ellipse, 1x circle", 10, 10)
show_step(p5, "scale + push/pop", 15, keyboard)

# Step 16: arc
p5.background(0x00)
p5.reset_matrix
PI = Math::PI
p5.fill(0xE0)
p5.stroke(0xFF)
p5.arc(160, 240, 100, 0, PI)
p5.fill(0x1C)
p5.arc(320, 240, 100, 0, PI * 0.75)
p5.fill(0x03)
p5.no_stroke
p5.arc(480, 240, 100, PI, PI * 1.75)
p5.text_color(0xFF)
p5.text("arc: 0-PI, 0-0.75PI, PI-1.75PI", 10, 10)
show_step(p5, "arc", 16, keyboard)

# Step 17: arc animation (circular progress bar)
PI = Math::PI
angle = 0.0
step = PI * 2 / 60
cx = W / 2
cy = H / 2
120.times do
  p5.background(0x00)
  p5.no_fill
  p5.stroke(p5.color(80, 80, 80))
  p5.circle(cx, cy, 100)
  p5.fill(p5.color(0, 200, 0))
  p5.no_stroke
  p5.arc(cx, cy, 100, -PI / 2, -PI / 2 + angle)
  pct = (angle / (PI * 2) * 100).to_i
  p5.text_font(G::FONT_SPLEEN_12X24)
  p5.text_color(0xFF)
  p5.text("#{pct}%", cx - 24, cy - 12)
  p5.commit
  angle += step
  angle -= PI * 2 if angle >= PI * 2
end
p5.text("arc animation: progress bar", 10, 10)
show_step(p5, "arc animation", 17, keyboard)

# Step 18: bezier + curve
p5.background(0x00)
p5.reset_matrix
p5.no_fill
p5.stroke(0xFF)
p5.bezier(40, 300, 160, 40, 480, 40, 600, 300)
p5.stroke(0xE0)
p5.bezier(40, 400, 200, 100, 440, 100, 600, 400)
p5.stroke(0x1C)
p5.curve(0, 480, 100, 200, 540, 200, 640, 480)
p5.text_color(0xFF)
p5.text("bezier (white, red) + curve (green)", 10, 10)
show_step(p5, "bezier + curve", 18, keyboard)

# Step 19: 320x240 resolution
G.set_resolution(320, 240)
p5.background(0x00)
p5.fill(0xE0)
p5.stroke(0xFF)
p5.rect(10, 10, 100, 60)
p5.fill(0x1C)
p5.circle(200, 120, 50)
p5.fill(0x03)
p5.triangle(250, 200, 310, 100, 310, 200)
p5.text_font(G::FONT_MPLUS_12)
p5.text_color(0xFF)
p5.text("320x240 mode (#{p5.width}x#{p5.height})", 10, 220)
show_step(p5, "320x240", 19, keyboard)

# Step 20: 320x240 arc animation
PI = Math::PI
angle = 0.0
stp = PI * 2 / 60
cx = p5.width / 2
cy = p5.height / 2
120.times do
  p5.background(0x00)
  p5.no_fill
  p5.stroke(p5.color(80, 80, 80))
  p5.circle(cx, cy, 60)
  p5.fill(p5.color(0, 200, 0))
  p5.no_stroke
  p5.arc(cx, cy, 60, -PI / 2, -PI / 2 + angle)
  pct = (angle / (PI * 2) * 100).to_i
  p5.text_font(G::FONT_SPLEEN_12X24)
  p5.text_color(0xFF)
  p5.text("#{pct}%", cx - 24, cy - 12)
  p5.commit
  angle += stp
  angle -= PI * 2 if angle >= PI * 2
end
p5.text_font(G::FONT_MPLUS_12)
p5.text_color(0xFF)
p5.text("320x240 arc animation", 10, 10)
show_step(p5, "320x240 arc anim", 20, keyboard)

# Step 21: back to 640x480
G.set_resolution(640, 480)
p5.background(0x00)
p5.fill(0xE0)
p5.stroke(0xFF)
p5.rect(40, 60, 260, 180)
p5.fill(0x1C)
p5.circle(480, 240, 100)
p5.text_font(G::FONT_SPLEEN_12X24)
p5.text_color(0xFF)
p5.text("Back to 640x480 (#{p5.width}x#{p5.height})", 10, 10)
show_step(p5, "640x480 restored", 21, keyboard)

# Step 22: text_align + text_width
p5.background(0x00)
p5.text_font(G::FONT_SPLEEN_12X24)
p5.text_color(0xE0)
p5.stroke(p5.color(80, 80, 80))
p5.no_fill
cx = p5.width / 2
# Center line
p5.line(cx, 0, cx, p5.height)

p5.text_align(:left)
p5.text_color(0xFF)
p5.text("LEFT aligned", cx, 60)

p5.text_align(:center)
p5.text_color(0x1C)
p5.text("CENTER aligned", cx, 120)

p5.text_align(:right)
p5.text_color(0x03)
p5.text("RIGHT aligned", cx, 180)

p5.text_align(:center, :center)
p5.text_color(0xE0)
p5.text("V-CENTER", cx, 280)

p5.text_align(:center, :bottom)
p5.text_color(0xFC)
p5.text("V-BOTTOM", cx, 360)

p5.text_align(:left)
p5.text_font(G::FONT_MPLUS_12, G::FONT_MPLUS_J12)
p5.text_color(0xFF)
w = p5.text_width("text_width = ")
p5.text("text_width = #{w}px", 10, 420)
show_step(p5, "text_align + text_width", 22, keyboard)

# Step 23: combined scene
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
show_step(p5, "combined scene", 23, keyboard)

# Restore text mode
DVI.set_mode(DVI::TEXT_MODE)
DVI::Text.clear(0xF0)
DVI::Text.put_string(0, 0, "P5 test complete!", 0x2F)
DVI::Text.commit
