# p5_game_demo: Interactive game demo with P5 graphics and keyboard input
#
# Arrow keys to move, collect stars to score points.
# Press Ctrl-C or Escape to quit.

require "p5"

keyboard = $keyboard
p5 = P5.new

W = p5.width
H = p5.height

# Colors (RGB332)
BLACK   = 0x00
WHITE   = 0xFF
RED     = 0xE0
GREEN   = 0x1C
BLUE    = 0x03
YELLOW  = 0xFC
CYAN    = 0x1F
MAGENTA = 0xE3

# Player state
player_x = W / 2
player_y = H / 2
player_size = 12
player_speed = 4
score = 0

# Stars
stars = []
12.times do
  stars << { x: 20 + (Machine.board_millis % (W - 40)),
             y: 20 + ((Machine.board_millis * 7 + stars.length * 97) % (H - 60)) }
end

# Obstacles
obstacles = []
6.times do |i|
  obstacles << { x: 60 + i * 90, y: 80 + (i * 67 % (H - 160)), w: 40, h: 30 }
end

def collide_circle_circle(x1, y1, r1, x2, y2, r2)
  dx = x1 - x2
  dy = y1 - y2
  dist = r1 + r2
  dx * dx + dy * dy <= dist * dist
end

def collide_circle_rect(cx, cy, cr, rx, ry, rw, rh)
  nx = cx < rx ? rx : (cx > rx + rw ? rx + rw : cx)
  ny = cy < ry ? ry : (cy > ry + rh ? ry + rh : cy)
  dx = cx - nx
  dy = cy - ny
  dx * dx + dy * dy <= cr * cr
end

frame = 0

p5.text_font(DVI::Graphics::FONT_MPLUS_12)

loop do
  # Input: drain all queued keys
  dx = 0
  dy = 0
  loop do
    key = keyboard.read_char
    break unless key
    case key
    when Keyboard::CTRL_C, Keyboard::ESCAPE
      return
    when Keyboard::LEFT
      dx -= player_speed
    when Keyboard::RIGHT
      dx += player_speed
    when Keyboard::UP
      dy -= player_speed
    when Keyboard::DOWN
      dy += player_speed
    end
  end

  # Try moving, push back if colliding with obstacle
  new_x = player_x + dx
  new_y = player_y + dy

  # Clamp to screen
  new_x = player_size if new_x < player_size
  new_x = W - player_size if new_x > W - player_size
  new_y = player_size + 16 if new_y < player_size + 16
  new_y = H - player_size if new_y > H - player_size

  # Obstacle collision (circle vs rectangle)
  hit = false
  obstacles.each do |ob|
    if collide_circle_rect(new_x, new_y, player_size, ob[:x], ob[:y], ob[:w], ob[:h])
      hit = true
      break
    end
  end

  unless hit
    player_x = new_x
    player_y = new_y
  end

  # Collect stars
  stars.each_with_index do |star, i|
    next unless star
    if collide_circle_circle(player_x, player_y, player_size, star[:x], star[:y], 6)
      score += 1
      # Respawn star at new position
      stars[i] = { x: 20 + ((Machine.board_millis + i * 131) % (W - 40)),
                   y: 20 + ((Machine.board_millis + i * 79) % (H - 60)) }
    end
  end

  # Draw
  p5.background(BLACK)

  # HUD
  p5.text_color(WHITE)
  p5.text("Score: #{score}", 8, 2)
  p5.text_color(0x49)
  p5.text("Arrow keys: move  Esc: quit", W / 2 - 100, 2)

  # Obstacles
  p5.fill(0x49)
  p5.no_stroke
  obstacles.each do |ob|
    p5.rect(ob[:x], ob[:y], ob[:w], ob[:h])
  end

  # Stars (blinking)
  p5.no_stroke
  stars.each_with_index do |star, i|
    next unless star
    blink = ((frame + i * 5) / 8) % 2 == 0
    p5.fill(blink ? YELLOW : WHITE)
    # Draw star as small diamond
    sx = star[:x]
    sy = star[:y]
    p5.triangle(sx, sy - 6, sx - 5, sy + 3, sx + 5, sy + 3)
    p5.triangle(sx, sy + 6, sx - 5, sy - 3, sx + 5, sy - 3)
  end

  # Player
  p5.fill(CYAN)
  p5.stroke(WHITE)
  p5.circle(player_x, player_y, player_size)
  # Eyes
  p5.fill(WHITE)
  p5.no_stroke
  p5.circle(player_x - 4, player_y - 3, 3)
  p5.circle(player_x + 4, player_y - 3, 3)
  p5.fill(BLACK)
  p5.circle(player_x - 3, player_y - 3, 1)
  p5.circle(player_x + 5, player_y - 3, 1)

  p5.commit
  frame += 1
end
