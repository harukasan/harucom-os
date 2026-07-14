# ika_fishing: Hakodate squid-fishing game

require "ssd1306"
require "board/pad"

WIDTH  = 128
HEIGHT = 64
HIGH_SCORE_PATH = "/etc/ika_score.txt"

GAME_DURATION_MS         = 20_000
SQUID_LIFETIME_MS        = 2_500
CATCH_ANIM_MS            = 220
SPAWN_INTERVAL_MIN       = 350
SPAWN_INTERVAL_VAR       = 500
FRAME_MS                 = 16
POINTS_PER_CATCH         = 10
TIMER_BAR_H              = 6
GAME_OVER_INPUT_DELAY_MS = 2_000

# 12x12 squid sprite (row-major, MSB-first, 2 bytes per row)
#  .....##.....
#  ....####....
#  ...######...
#  ..########..
#  .##########.
#  #.########.#
#  .##.####.##.
#  .##########.
#  .##..##..##.
#  .#.##..##.#.
#  #.#.#..#.#.#
#  ..#..##..#..
SQUID_SPRITE =
  "\x06\x00" +
  "\x0F\x00" +
  "\x1F\x80" +
  "\x3F\xC0" +
  "\x7F\xE0" +
  "\xBF\xD0" +
  "\x6F\x60" +
  "\x7F\xE0" +
  "\x66\x60" +
  "\x59\xA0" +
  "\xA9\x50" +
  "\x26\x40"
SQUID_W = 12
SQUID_H = 12

# Board::Pad button IDs: RIGHT=0, UP=1, DOWN=2, LEFT=3
# SLOTS[i] = [x, y, pad_index (0=left,1=right), button_id]
# Mirror the cross layout of the left/right pads onto the screen,
# giving 4 slots per side for 8 slots total.
SLOTS = [
  # Left pad (PAD0) -> left half of the screen (cx=32, cy=32)
  [26, 10, 0, Board::Pad::UP],
  [26, 42, 0, Board::Pad::DOWN],
  [ 8, 26, 0, Board::Pad::LEFT],
  [44, 26, 0, Board::Pad::RIGHT],
  # Right pad (PAD1) -> right half of the screen (cx=96, cy=32)
  [ 90, 10, 1, Board::Pad::UP],
  [ 90, 42, 1, Board::Pad::DOWN],
  [ 72, 26, 1, Board::Pad::LEFT],
  [108, 26, 1, Board::Pad::RIGHT],
]

def load_high_score
  return 0 unless File.exist?(HIGH_SCORE_PATH)
  File.open(HIGH_SCORE_PATH, "r") { |f| f.read.to_i }
rescue => e
  puts "load_high_score: #{e.message}"
  0
end

def save_high_score(score)
  File.open(HIGH_SCORE_PATH, "w") { |f| f.write(score.to_s) }
rescue => e
  puts "save_high_score: #{e.message}"
end

def draw_squid(display, x, y)
  display.draw_bytes(x: x, y: y, w: SQUID_W, h: SQUID_H, data: SQUID_SPRITE)
end

def draw_catch_anim(display, x, y, phase)
  # phase: 0.0-1.0. Expanding rectangle outline creates a "pop and vanish" effect.
  cx = x + 6
  cy = y + 6
  size = 12 + (18.0 * phase).to_i
  half = size / 2
  display.draw_rect(cx - half, cy - half, size, size, 1, false)
  # In the second phase, add a cross-shaped dashed line to emphasize the burst.
  if phase > 0.4
    inner = size - 6
    inner = 4 if inner < 4
    ih = inner / 2
    display.draw_line(cx - ih, cy, cx + ih, cy, 1)
    display.draw_line(cx, cy - ih, cx, cy + ih, 1)
  end
end

def read_pads(left_pad, right_pad)
  left_pad.read
  right_pad.read
end

def wait_any_press(left_pad, right_pad)
  # Wait until all buttons are released, then detect the first press.
  # This prevents an immediate advance from a button held down on the previous screen.
  loop do
    read_pads(left_pad, right_pad)
    break if left_pad.state == 0 && right_pad.state == 0
    sleep_ms 10
  end
  loop do
    read_pads(left_pad, right_pad)
    break if left_pad.state != 0 || right_pad.state != 0
    sleep_ms 10
  end
end

def draw_start_screen(display, high_score)
  display.clear
  display.draw_text(:shinonome_maru12, 10,  4, "函館イカ釣りゲーム")
  display.draw_text(:shinonome_maru12, 16, 28, "ボタンでスタート")
  display.draw_text(:shinonome_maru12, 10, 50, "ハイスコア:")
  display.draw_text(:terminus_6x12,    86, 50, "#{high_score}")
  display.update_display
end

def draw_game_over_screen(display, score, high_score, new_record)
  display.clear
  display.draw_text(:shinonome_maru12, 22, 0, "ゲームオーバー")
  draw_squid(display, 10, 20)
  display.draw_text(:terminus_6x12, 30, 18, "SCORE #{score}")
  label = new_record ? "NEW!!" : "HIGH "
  display.draw_text(:terminus_6x12, 30, 32, "#{label}#{high_score}")
  display.draw_text(:shinonome_maru12, 10, 50, "ボタンで再スタート")
  display.update_display
end

def show_countdown(display)
  # Pre-game overlay: show every squid spawn position so the player can
  # memorize the layout, with a 3-2-1 countdown in the center.
  i = 3
  while i >= 1
    display.erase(0, 0, WIDTH, HEIGHT)
    j = 0
    while j < SLOTS.size
      slot = SLOTS[j]
      draw_squid(display, slot[0], slot[1])
      j += 1
    end
    # terminus_16x32 "3" is 16x32, so (128-16)/2=56, (64-32)/2=16 centers it.
    display.draw_text(:terminus_16x32, 56, 16, i.to_s)
    display.update_display
    sleep_ms 1000
    i -= 1
  end
  # Clear tutorial and flash a start banner before the game loop kicks in.
  display.erase(0, 0, WIDTH, HEIGHT)
  # shinonome_go16 "スタート！" is 5 chars * 16 = 80px wide.
  display.draw_text(:shinonome_go16, 24, 24, "スタート！")
  display.update_display
  sleep_ms 700
end

def play_game(display, left_pad, right_pad)
  # slot_state[i] = [spawned_at_ms or nil, catch_at_ms or nil]
  slot_state = []
  i = 0
  while i < SLOTS.size
    slot_state << [nil, nil]
    i += 1
  end

  score = 0
  start_ms = Machine.board_millis
  next_spawn_ms = start_ms + 300
  last_left = 0
  last_right = 0

  while true
    now = Machine.board_millis
    remaining_ms = GAME_DURATION_MS - (now - start_ms)
    break if remaining_ms <= 0

    # --- Input ---
    read_pads(left_pad, right_pad)
    lstate = left_pad.state
    rstate = right_pad.state
    l_new = lstate & ~last_left
    r_new = rstate & ~last_right
    last_left = lstate
    last_right = rstate

    # --- Spawn ---
    if now >= next_spawn_ms
      empty = []
      i = 0
      while i < slot_state.size
        empty << i if slot_state[i][0].nil?
        i += 1
      end
      if !empty.empty?
        pick = empty[rand(empty.size)]
        slot_state[pick] = [now, nil]
      end
      next_spawn_ms = now + SPAWN_INTERVAL_MIN + rand(SPAWN_INTERVAL_VAR)
    end

    # --- Update slot states (catch / expire / animation end) ---
    i = 0
    while i < slot_state.size
      spawned_at = slot_state[i][0]
      catch_at   = slot_state[i][1]
      slot = SLOTS[i]
      pad_idx = slot[2]
      btn     = slot[3]
      mask    = 1 << btn

      if spawned_at && catch_at.nil?
        newly = pad_idx == 0 ? l_new : r_new
        if (newly & mask) != 0
          slot_state[i] = [spawned_at, now]
          score += POINTS_PER_CATCH
        elsif now - spawned_at > SQUID_LIFETIME_MS
          slot_state[i] = [nil, nil]
        end
      elsif catch_at
        if now - catch_at >= CATCH_ANIM_MS
          slot_state[i] = [nil, nil]
        end
      end
      i += 1
    end

    # --- Draw ---
    # Clear the VRAM only. Do not use display.clear: it sends an empty
    # frame over I2C and causes flicker between drawing frames.
    display.erase(0, 0, WIDTH, HEIGHT)

    # Timer: bar on the left, remaining seconds on the right. Cap the bar
    # width at 96px and reserve the remaining 32px for the number so the
    # x range does not collide with the top-right sprite (right pad UP:
    # x=90-101).
    timer_bar_max = 96
    bar_w = (timer_bar_max * remaining_ms) / GAME_DURATION_MS
    bar_w = 0 if bar_w < 0
    bar_w = timer_bar_max if bar_w > timer_bar_max
    display.draw_rect(0, 0, bar_w, TIMER_BAR_H, 1, true)
    seconds_left = (remaining_ms + 999) / 1000
    display.draw_text(:terminus_6x12, 108, 0, "#{seconds_left}s")

    # Slots
    i = 0
    while i < slot_state.size
      spawned_at = slot_state[i][0]
      catch_at   = slot_state[i][1]
      slot = SLOTS[i]
      x = slot[0]
      y = slot[1]

      if spawned_at && catch_at.nil?
        draw_squid(display, x, y)
      elsif catch_at
        phase = (now - catch_at).to_f / CATCH_ANIM_MS
        phase = 1.0 if phase > 1.0
        draw_catch_anim(display, x, y, phase)
      end
      i += 1
    end

    # Every page is dirty, so update_display beats the optimized variant
    # in I2C transaction count: the SSD1306 auto-increments the address,
    # so the range only needs to be set once.
    display.update_display

    if RUBY_ENGINE == "mruby"
      GC.start
    end
    sleep_ms FRAME_MS
  end

  score
end

# --- Main ---

i2c = I2C.new(unit: :RP2040_I2C1, sda_pin: 26, scl_pin: 27, frequency: 400_000)
display = SSD1306.new(i2c: i2c, w: WIDTH, h: HEIGHT)

left_pad  = Board::Pad.new(Board::PAD0_PIN)
right_pad = Board::Pad.new(Board::PAD1_PIN)

high_score = load_high_score

loop do
  draw_start_screen(display, high_score)
  wait_any_press(left_pad, right_pad)

  show_countdown(display)
  score = play_game(display, left_pad, right_pad)

  new_record = score > high_score
  if new_record
    high_score = score
    save_high_score(high_score)
  end

  draw_game_over_screen(display, score, high_score, new_record)
  # Ignore button input for a short period so a stray press right after
  # the game ends does not immediately start the next round.
  sleep_ms GAME_OVER_INPUT_DELAY_MS
  wait_any_press(left_pad, right_pad)
end
