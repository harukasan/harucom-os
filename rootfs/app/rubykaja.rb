# rubykaja: PicoPicoRuby celebration animation for makicamel's RubyKaja award
# at Sekigahara Ruby Kaigi 2026.
#
# A steam locomotive with tender travels from Sekigahara battlefield, past
# Mt. Fuji, to Tokyo (Akihabara). Each scene element lives at a fixed world
# x and scrolls past at its own parallax (slower = farther), so transitions
# are seamless: Sekigahara peaks drift off to the left, then Fuji emerges
# from the right, drifts gently across, exits left, and Tokyo follows.
#
# Usage:
#   /app/rubykaja [seconds]   # default 150 seconds (2.5 min)
# Keys:
#   Space = start / goal / restart
#   1 / 2 / 3 = pick timer preset (150 / 60 / 30 seconds)
#   Esc or Ctrl-C = quit

require "p5"

DVI::Graphics.set_resolution(320, 240)
p5 = P5.new
keyboard = $keyboard

W = p5.width
H = p5.height

# ===== Palette (RGB332 grid: R/G in 32 steps, B in 64 steps) =====
SKY_TOP    = p5.color(160, 192, 192)
SKY_MID    = p5.color(192, 224, 192)
HAZE       = p5.color(192, 224, 192)
SUN_CORE   = p5.color(255, 255, 192)
SUN_RIM    = p5.color(224, 192, 128)
CLOUD_TOP  = p5.color(255, 255, 255)
CLOUD_MID  = p5.color(224, 224, 192)
CLOUD_SHAD = p5.color(160, 160, 192)
FAR_MTN    = p5.color(128, 160, 192)
MID_MTN    = p5.color( 96, 128, 160)
NEAR_MTN   = p5.color( 64,  96, 128)
SNOW_CAP   = p5.color(255, 255, 255)
SNOW_SHADE = p5.color(192, 192, 224)
FUJI_BODY  = p5.color( 96, 128, 192)
FUJI_SHAD  = p5.color( 64,  96, 128)
GROUND_SKY = p5.color(192, 224, 160)
GRASS_LITE = p5.color(160, 224,  64)
GRASS      = p5.color( 96, 192,  64)
GRASS_DARK = p5.color( 64, 128,   0)
TRUNK      = p5.color( 96,  64,   0)
TRUNK_DARK = p5.color( 64,  32,   0)
LEAF_LITE  = p5.color(128, 224,  64)
LEAF_MID   = p5.color( 96, 160,   0)
LEAF_DARK  = p5.color( 32,  96,   0)
LOCO_BLACK = p5.color( 32,  32,   0)
LOCO_BODY  = p5.color( 64,  64,  64)
LOCO_LITE  = p5.color(128, 128, 128)
LOCO_RIVET = p5.color(160, 160, 192)
LOCO_RED   = p5.color(192,  32,   0)
LOCO_DARKRED = p5.color(128,   0,   0)
BRASS      = p5.color(192, 128,   0)
BRASS_LITE = p5.color(224, 192,   0)
WINDOW_LIT = p5.color(255, 224, 128)
COAL_BLK   = p5.color(  0,   0,   0)
COAL_DARK  = p5.color( 32,  32,   0)
COAL_HI    = p5.color( 96,  96,  64)
SMOKE_DK   = p5.color( 64,  64,  64)
SMOKE_MID  = p5.color(128, 128, 128)
SMOKE_LT   = p5.color(192, 192, 192)
STEAM_LT   = p5.color(224, 224, 192)
FIRE_RED   = p5.color(224,  32,   0)
FIRE_ORG   = p5.color(255, 128,   0)
FIRE_YLW   = p5.color(255, 224,  64)
RAIL_DARK  = p5.color( 64,  64,  64)
TIE        = p5.color( 96,  64,   0)
GRAVEL     = p5.color(128, 128, 128)
WHITE      = p5.color(255, 255, 255)
BLACK      = p5.color(  0,   0,   0)
BUILD_A    = p5.color(160, 128, 128)
BUILD_B    = p5.color(128, 128, 160)
BUILD_C    = p5.color( 96,  96, 128)
WINDOW_DAY = p5.color(160, 192, 224)
NEON_PINK  = p5.color(224,  64, 128)
TOWER_RED  = p5.color(224,  64,   0)
FUJI_NAVY  = p5.color( 64,  96, 128)
RUBY_RED   = p5.color(224,   0,   0)
RUBY_BLUSH = p5.color(240, 128, 128)
# Magenta marker used as the transparent color key in pre-rendered sprites.
# Not used anywhere else in the palette.
TRANS_KEY  = p5.color(255,   0, 255)

# ===== Layout (320x240) =====
LOCO_X    = 178
LOCO_Y    = 174
TENDER_X  = 95
RAIL_Y    = 196
HUD_H     = 18
HORIZON_Y = 150
GROUND_Y  = 156

# Locomotive sprite dimensions. The static parts (boiler / cab / smoke box /
# tender body etc.) are pre-rendered once into a buffer of this size; each
# frame blits the buffer and overdraws the wheels and side rod. The (BX, BY)
# point inside the sprite corresponds to the locomotive's base_x, base_y.
LOCO_SPRITE_W  = 152
LOCO_SPRITE_H  = 46
LOCO_SPRITE_BX = 108
LOCO_SPRITE_BY = 28

PHASE_COUNTDOWN_MS = 3_000
PHASE_START_MS     = 1_500
PHASE_RESULT_MS    = 2_200

# Target ~30fps. Animations using `frame / N` divisors were tuned for 60fps,
# so `frame` advances by 2 per iteration to keep the same wall-clock pacing.
FRAME_INTERVAL_MS = 33

# ===== Parallax per element type =====
# bg_offset is the global scroll (in screen px). Each element computes its
# screen position as: screen_x = world_x - bg_offset / parallax. Lower
# parallax = closer = faster scroll. Higher parallax = farther = slower.
PARALLAX_CLOUD =  9
PARALLAX_FAR   =  6
PARALLAX_MID   =  5
PARALLAX_NEAR  =  4
PARALLAX_TREE  =  3
PARALLAX_FLAG  =  3
PARALLAX_FUJI  = 14
PARALLAX_TOWER = 16
PARALLAX_BUILD =  4

# ===== Wheel spokes (8 phases x 4 spokes) =====
WHEEL_SPOKES = [
  [ 6,  0, -6,  0,  0,  6,  0, -6],
  [ 5,  3, -5, -3, -3,  5,  3, -5],
  [ 4,  4, -4, -4, -4,  4,  4, -4],
  [ 3,  5, -3, -5, -5,  3,  5, -3],
  [ 0,  6,  0, -6, -6,  0,  6,  0],
  [-3,  5,  3, -5, -5, -3,  5,  3],
  [-4,  4,  4, -4, -4, -4,  4,  4],
  [-5,  3,  5, -3, -3, -5,  3,  5],
]

# Flag wave: per-row right-edge offset for 4 phases
FLAG_WAVE = [
  [0, 1, 2, 1],
  [1, 2, 1, 0],
  [2, 1, 0, 1],
  [1, 0, 1, 2],
]

# Sengoku battle flag types. Stylized after Sekigahara nobori-bata.
FLAG_TYPES = [:mitsunari, :ieyasu, :naomasa, :nagamasa, :morichika]

# ===== Sekigahara world (world_x 0..2400) =====
# Far mountains extend across all phases as the distant backdrop. Tokyo
# buildings draw over them in their own phase, so they vanish naturally.
SEKI_FAR_END  = 12000
SEKI_MID_END  = 2400
SEKI_NEAR_END = 2400
SEKI_TREE_END = 2200
SEKI_FLAG_END = 2200

SEKI_FAR_PEAKS = []
n = 0
while n * 60 < SEKI_FAR_END
  SEKI_FAR_PEAKS << [n * 60 + ((n * 7) % 10) - 5, 22 + (n * 13) % 14]
  n += 1
end

SEKI_MID_PEAKS = []
n = 0
while n * 86 < SEKI_MID_END
  SEKI_MID_PEAKS << [n * 86 + ((n * 11) % 14) - 7, 38 + (n * 17) % 14]
  n += 1
end

SEKI_NEAR_PEAKS = []
n = 0
while n * 122 < SEKI_NEAR_END
  SEKI_NEAR_PEAKS << [n * 122 + ((n * 19) % 16) - 8, 56 + (n * 23) % 18]
  n += 1
end

SEKI_TREES = []
n = 0
while n * 32 < SEKI_TREE_END
  SEKI_TREES << [n * 32 + ((n * 5) % 8) - 4, n & 1]
  n += 1
end

SEKI_FLAGS = []
n = 0
while n * 44 < SEKI_FLAG_END
  size = ((n * 3) & 3) == 0 ? :large : :small
  SEKI_FLAGS << [n * 44, n % 5, size]
  n += 1
end

# Clouds drift across all phases. World range covers the whole journey.
# y is offset below the HUD (HUD_H = 18) so clouds aren't hidden by it.
CLOUDS = []
n = 0
while n * 56 < 8000
  CLOUDS << [n * 56 + ((n * 11) % 22) - 800, 28 + (n * 13) % 22, 3 + (n * 7) % 3]
  n += 1
end

# ===== Mt. Fuji (single instance, very slow parallax) =====
FUJI_WORLD_X = 1700

# Right-half silhouette as [y_offset_from_base, half_width]. The Fuji
# silhouette people recognize is a flat-topped trapezoid that widens with
# mostly straight slopes and a small flare at the very base.
FUJI_BODY_POINTS = [
  [-92,  14],
  [-86,  20],
  [-46,  56],
  [-10,  96],
  [  0, 116],
]

# Snow cap. Follows the mountain outline at every point so its left and
# right edges always sit on the silhouette - never a slice of body color
# showing past the snow on the sides. The bottom half-width 42 is the
# interpolated body width at y=-62.
FUJI_SNOW_POINTS = [
  [-92, 14],
  [-86, 20],
  [-62, 42],
]

# Snow tongues hanging down past the cap. Center fingers reach deepest,
# edges are shallow - the recognizable Fuji silhouette.
FUJI_SNOW_FINGERS = [
  [-34,  3,  4],
  [-24,  3,  7],
  [-12,  3, 11],
  [  0,  3, 14],
  [ 12,  3, 10],
  [ 24,  3,  7],
  [ 34,  3,  5],
]

# Companion mountains around Fuji (Kai/Tanzawa range). Positions relative to
# Fuji's world_x so they scroll together at PARALLAX_FUJI.
FUJI_RANGE_MOUNTAINS = [
  [-180, 22], [-140, 30], [-110, 22], [-86, 18],
  [ 90,  20], [120,  28], [150,  24], [188, 18],
]

# ===== Tokyo (Akihabara skyline) =====
TOWER_WORLD_X = 3300

TOKYO_BUILDINGS = []
seed = 0
wx = 7600
while wx < 16000
  seed += 1
  h = 50 + (seed * 17 + 11) % 70
  bw = 16 + (seed * 7) % 12
  color_id = seed % 3
  TOKYO_BUILDINGS << [wx, h, bw, color_id]
  wx += bw + 4 + (seed * 5) % 6
end

def fmt_time(ms)
  ms = 0 if ms < 0
  total = ms / 1000
  m = total / 60
  s = total % 60
  s < 10 ? m.to_s + ":0" + s.to_s : m.to_s + ":" + s.to_s
end

def drain_input(keyboard)
  enter = false
  quit = false
  preset = nil
  loop do
    key = keyboard.read_char
    break unless key
    case key
    when Keyboard::CTRL_C, Keyboard::ESCAPE
      quit = true
    else
      # Space advances the state. Enter is intentionally not used because the
      # previous shell may still be listening for it when this app starts.
      # 1 / 2 / 3 pick a total-time preset (150s / 60s / 30s).
      case key.char
      when " " then enter = true
      when "1" then preset = 150
      when "2" then preset = 60
      when "3" then preset = 30
      end
    end
  end
  [enter, quit, preset]
end

def speed_for(state, elapsed, warmup_ms, running_ms)
  case state
  when :warmup
    0.4 + (elapsed.to_f / warmup_ms) * 0.6
  when :running
    ratio = elapsed.to_f / running_ms
    ratio = 1.0 if ratio > 1.0
    1.0 + ratio * 4.5
  else
    0.0
  end
end

# Derive the timer-dependent values from a total length in seconds. Returns
# [total_ms, warmup_ms, running_ms, journey_scale]. The journey_scale lets
# bg_offset advance proportionally faster on shorter runs so Tokyo is still
# reached within the chosen total time.
def derive_timer(total_seconds)
  total_ms = total_seconds * 1000
  warmup_ms = total_ms / 5
  warmup_ms = 30_000 if warmup_ms > 30_000
  running_ms = total_ms - warmup_ms
  journey_scale = 150.0 / total_seconds
  [total_ms, warmup_ms, running_ms, journey_scale]
end

def clear_smoke(particles)
  i = 0
  while i < particles.length
    particles[i] = nil
    i += 1
  end
end

# ===== Sky / clouds / sun =====

def draw_sky(p5)
  p5.no_stroke
  # Top sky band sits below the HUD area; the HUD redraws on top of it later
  # but the clouds and sun live in this region so they remain visible.
  p5.fill(SKY_TOP)
  p5.rect(0, 0, W, 56)
  p5.fill(SKY_MID)
  p5.rect(0, 56, W, 56)
  p5.fill(HAZE)
  p5.rect(0, 112, W, HORIZON_Y - 112)
end

def draw_sun(p5)
  p5.no_stroke
  p5.fill(SUN_RIM)
  p5.circle(286, 44, 10)
  p5.fill(SUN_CORE)
  p5.circle(286, 44, 8)
end

def draw_clouds(p5, bg_offset)
  off = bg_offset / PARALLAX_CLOUD
  p5.no_stroke
  # CLOUDS are stored in increasing world_x order (n * 56 + small jitter),
  # so each pass can early-break once world_x is past the right edge.
  right_limit = W + 20
  # Pass 1: shadow band (CLOUD_SHAD)
  p5.fill(CLOUD_SHAD)
  i = 0
  while i < CLOUDS.length
    c = CLOUDS[i]
    sx = c[0] - off
    break if sx > right_limit
    if sx > -20
      s = c[2]
      p5.rect(sx - s * 2, c[1] + s - 1, s * 4, 2)
    end
    i += 1
  end
  # Pass 2: mid layer (CLOUD_MID)
  p5.fill(CLOUD_MID)
  i = 0
  while i < CLOUDS.length
    c = CLOUDS[i]
    sx = c[0] - off
    break if sx > right_limit
    if sx > -20
      s = c[2]
      p5.circle(sx - s, c[1], s)
      p5.circle(sx + s, c[1], s)
    end
    i += 1
  end
  # Pass 3: highlights (CLOUD_TOP)
  p5.fill(CLOUD_TOP)
  i = 0
  while i < CLOUDS.length
    c = CLOUDS[i]
    sx = c[0] - off
    break if sx > right_limit
    if sx > -20
      s = c[2]
      p5.circle(sx, c[1] - 1, s + 1)
      p5.circle(sx - s * 2, c[1] + 1, s - 1)
      p5.circle(sx + s * 2, c[1] + 1, s - 1)
    end
    i += 1
  end
end

# ===== Sekigahara mountains =====

def draw_mountain(p5, sx, sy, half_w, body_col, shadow_col, snow_col)
  p5.fill(body_col)
  p5.triangle(sx - half_w, HORIZON_Y, sx + half_w, HORIZON_Y, sx, sy)
  # Sunlit/shaded sides
  p5.fill(shadow_col)
  p5.triangle(sx, sy, sx + half_w, HORIZON_Y, sx + half_w / 3, HORIZON_Y)
  # Snow cap omitted for performance. snow_col arg is kept for call-site
  # compatibility; Fuji draws its own snow separately.
end

# Mountain sprite buckets: 3 quantized heights per layer. Original heights
# vary by ~14-18 pixels; bucketing into 3 keeps visual variety while letting
# each frame just blit instead of issuing 4 ops per mountain.
FAR_MTN_BUCKETS  = [25, 29, 34]
MID_MTN_BUCKETS  = [41, 45, 50]
NEAR_MTN_BUCKETS = [60, 65, 72]

# Render a single mountain (body + right-side shadow triangles) into a
# transparent-keyed sprite. The sprite is sized exactly to enclose the
# triangles; its apex sits at sprite (half_w, 0) and base at y=h.
def render_mountain_to_sprite(sprite, half_w, h, body_col, shadow_col)
  sprite.background(TRANS_KEY)
  sprite.no_stroke
  sprite.fill(body_col)
  sprite.triangle(0, h, half_w * 2, h, half_w, 0)
  sprite.fill(shadow_col)
  sprite.triangle(half_w, 0, half_w * 2, h, half_w + half_w / 3, h)
end

def build_mountain_sprites(p5, half_w, buckets, body_col, shadow_col)
  out = []
  w = half_w * 2 + 1
  i = 0
  while i < buckets.length
    h = buckets[i]
    sprite = p5.create_graphics(w, h + 1)
    render_mountain_to_sprite(sprite, half_w, h, body_col, shadow_col)
    out << sprite
    i += 1
  end
  out
end

# Pick the bucket index whose sprite height best matches the target height.
def mountain_bucket_for(buckets, h)
  if h <= buckets[0]
    0
  elsif h <= buckets[1]
    1
  else
    2
  end
end

def blit_mountain(p5, sprites, buckets, sx, h, half_w)
  idx = mountain_bucket_for(buckets, h)
  sprite_h = buckets[idx]
  p5.blit(sprites[idx], sx - half_w, HORIZON_Y - sprite_h, TRANS_KEY)
end

def draw_far_mountains(p5, bg_offset)
  off = bg_offset / PARALLAX_FAR
  right_limit = W + 40
  i = 0
  while i < SEKI_FAR_PEAKS.length
    pk = SEKI_FAR_PEAKS[i]
    sx = pk[0] - off
    break if sx > right_limit
    if sx > -40
      blit_mountain(p5, FAR_MTN_SPRITES, FAR_MTN_BUCKETS, sx, pk[1], 26)
    end
    i += 1
  end
end

def draw_mid_mountains(p5, bg_offset)
  off = bg_offset / PARALLAX_MID
  right_limit = W + 50
  i = 0
  while i < SEKI_MID_PEAKS.length
    pk = SEKI_MID_PEAKS[i]
    sx = pk[0] - off
    break if sx > right_limit
    if sx > -50
      blit_mountain(p5, MID_MTN_SPRITES, MID_MTN_BUCKETS, sx, pk[1], 36)
    end
    i += 1
  end
end

def draw_near_mountains(p5, bg_offset)
  off = bg_offset / PARALLAX_NEAR
  right_limit = W + 60
  i = 0
  while i < SEKI_NEAR_PEAKS.length
    pk = SEKI_NEAR_PEAKS[i]
    sx = pk[0] - off
    break if sx > right_limit
    if sx > -60
      blit_mountain(p5, NEAR_MTN_SPRITES, NEAR_MTN_BUCKETS, sx, pk[1], 48)
    end
    i += 1
  end
end

# ===== Trees =====

def draw_pine_tree(p5, x, base_y)
  p5.no_stroke
  p5.fill(TRUNK_DARK)
  p5.rect(x - 1, base_y - 4, 3, 4)
  p5.fill(LEAF_DARK)
  p5.triangle(x - 6, base_y - 4, x + 6, base_y - 4, x, base_y - 14)
  p5.fill(LEAF_MID)
  p5.triangle(x - 5, base_y - 8, x + 5, base_y - 8, x, base_y - 16)
  p5.fill(LEAF_LITE)
  p5.triangle(x - 4, base_y - 12, x + 4, base_y - 12, x, base_y - 18)
end

def draw_round_tree(p5, x, base_y)
  p5.no_stroke
  p5.fill(TRUNK)
  p5.rect(x - 1, base_y - 6, 3, 6)
  p5.fill(LEAF_DARK)
  p5.circle(x, base_y - 11, 6)
  p5.fill(LEAF_MID)
  p5.circle(x - 1, base_y - 12, 5)
  p5.fill(LEAF_LITE)
  p5.circle(x - 2, base_y - 13, 3)
end

# Pine/round tree sprite dimensions. (CX, BY) is the sprite-local point
# corresponding to the world (x, base_y) anchor that draw_pine_tree /
# draw_round_tree paint around.
TREE_SPRITE_W   = 13
PINE_SPRITE_H   = 18
PINE_SPRITE_CX  = 6
PINE_SPRITE_BY  = 18
ROUND_SPRITE_H  = 17
ROUND_SPRITE_CX = 6
ROUND_SPRITE_BY = 17

def build_tree_sprites(p5)
  pine = p5.create_graphics(TREE_SPRITE_W, PINE_SPRITE_H)
  pine.background(TRANS_KEY)
  draw_pine_tree(pine, PINE_SPRITE_CX, PINE_SPRITE_BY)
  round = p5.create_graphics(TREE_SPRITE_W, ROUND_SPRITE_H)
  round.background(TRANS_KEY)
  draw_round_tree(round, ROUND_SPRITE_CX, ROUND_SPRITE_BY)
  [pine, round]
end

def draw_trees(p5, bg_offset)
  off = bg_offset / PARALLAX_TREE
  base_y = GROUND_Y + 4
  pine_y = base_y - PINE_SPRITE_BY
  round_y = base_y - ROUND_SPRITE_BY
  right_limit = W + 10
  i = 0
  while i < SEKI_TREES.length
    t = SEKI_TREES[i]
    sx = t[0] - off
    break if sx > right_limit
    if sx > -10
      if t[1] == 0
        p5.blit(PINE_SPRITE, sx - PINE_SPRITE_CX, pine_y, TRANS_KEY)
      else
        p5.blit(ROUND_SPRITE, sx - ROUND_SPRITE_CX, round_y, TRANS_KEY)
      end
    end
    i += 1
  end
end

# ===== Battle flags (Sekigahara nobori-bata) =====

def flag_field_color(type)
  case type
  when :mitsunari then WHITE
  when :ieyasu    then WHITE
  when :naomasa   then LOCO_RED
  when :nagamasa  then FUJI_SHAD
  when :morichika then BRASS_LITE
  end
end

def flag_motif_color(type)
  case type
  when :mitsunari then BLACK
  when :ieyasu    then BLACK
  when :naomasa   then WHITE
  when :nagamasa  then WHITE
  when :morichika then BLACK
  end
end

def draw_flag_field(p5, fx, top_y, base_w, flag_h, color, wave)
  rows = 4
  row_h = flag_h / rows
  r = 0
  while r < rows
    dx = wave[r]
    p5.fill(color)
    p5.rect(fx, top_y + r * row_h, base_w + dx, row_h + 1)
    r += 1
  end
end

def draw_flag_motif(p5, fx, top_y, base_w, flag_h, type, motif_col)
  cx = fx + base_w / 2
  case type
  when :mitsunari
    # "大一大万大吉" simplified to three stacked dark bars
    p5.fill(motif_col)
    p5.rect(fx + 1, top_y + flag_h / 6,     base_w - 2, 2)
    p5.rect(fx + 1, top_y + flag_h / 2 - 1, base_w - 2, 2)
    p5.rect(fx + 1, top_y + flag_h * 5 / 6, base_w - 2, 2)
  when :ieyasu
    # 三つ葉葵 - three leaf-petals around a central dot
    cy = top_y + flag_h / 2
    p5.fill(motif_col)
    p5.rect(cx - 1, cy - 3, 3, 2)
    p5.rect(cx - 3, cy + 1, 3, 2)
    p5.rect(cx + 1, cy + 1, 3, 2)
    p5.rect(cx, cy, 1, 1)
  when :naomasa
    # 井伊家の "本" simplified to a vertical bar with crossbar
    cy = top_y + flag_h / 2
    p5.fill(motif_col)
    p5.rect(cx, cy - 5, 1, 11)
    p5.rect(cx - 2, cy - 4, 5, 1)
    p5.rect(cx - 1, cy - 2, 3, 1)
  when :nagamasa
    # 黒田藤巴 - white ring with central tick
    cy = top_y + flag_h / 2
    p5.fill(motif_col)
    p5.circle(cx, cy, 4)
    p5.fill(flag_field_color(:nagamasa))
    p5.circle(cx, cy, 2)
    p5.fill(motif_col)
    p5.rect(cx, cy - 1, 1, 3)
  when :morichika
    # 長宗我部の七つ酢漿草 - three vertical dots
    p5.fill(motif_col)
    p5.rect(cx - 1, top_y + 4,           2, 2)
    p5.rect(cx - 1, top_y + flag_h / 2,  2, 2)
    p5.rect(cx - 1, top_y + flag_h - 6,  2, 2)
  end
end

# Sprite dimensions for pre-rendered flags. Both small and large flags
# share the same sprite layout convention: the pole sits at sprite x=2
# (base mount extends 2 px left of the pole), top_y in sprite coords is 2
# (crossbar is at sprite y=0), and the sprite extends down to pole_bot.
FLAG_SMALL_BASE_W = 7
FLAG_SMALL_FLAG_H = 24
FLAG_SMALL_W = FLAG_SMALL_BASE_W + 6
FLAG_SMALL_H = FLAG_SMALL_FLAG_H + 14
FLAG_LARGE_BASE_W = 9
FLAG_LARGE_FLAG_H = 30
FLAG_LARGE_W = FLAG_LARGE_BASE_W + 6
FLAG_LARGE_H = FLAG_LARGE_FLAG_H + 14

# Render a flag into a sprite with the wave already baked in. Each call
# produces one of the four wave-phase variants for a (type, size) pair.
def render_flag_to_sprite(sprite, type, base_w, flag_h, wave)
  pole_x = 2           # Sprite-local x of the pole
  field_x = pole_x + 2 # Field starts 2 px right of the pole
  top_y = 2            # Banner top (crossbar sits at sprite y=0)
  pole_bot = top_y + flag_h + 12
  field_col = flag_field_color(type)
  motif_col = flag_motif_color(type)

  sprite.background(TRANS_KEY)
  sprite.no_stroke
  sprite.fill(TRUNK_DARK)
  sprite.rect(pole_x, top_y - 2, 1, pole_bot - (top_y - 2))
  sprite.rect(pole_x + 1, top_y - 2, base_w + 2, 1)
  sprite.fill(TRUNK)
  sprite.rect(pole_x - 2, pole_bot - 2, 5, 2)
  sprite.fill(LOCO_BLACK)
  sprite.rect(pole_x + 3, top_y + 1, base_w + 1, flag_h + 1)
  # Field rows: extend each row by wave[r] pixels (overwriting the shadow
  # on the right side just like the original per-frame draw did).
  sprite.fill(field_col)
  row_h = flag_h / 4
  r = 0
  while r < 4
    sprite.rect(field_x, top_y + r * row_h, base_w + wave[r], row_h + 1)
    r += 1
  end
  sprite.fill(motif_col)
  sprite.rect(field_x, top_y, base_w, 2)
  draw_flag_motif(sprite, field_x, top_y + 3, base_w, flag_h - 4, type, motif_col)
end

# Build all 40 flag sprites (5 types x 2 sizes x 4 wave phases).
# Index layout: FLAG_SPRITES[type_idx * 8 + size_idx * 4 + wave_idx]
# where size_idx is 0 for small, 1 for large.
def build_flag_sprites(p5)
  sprites = []
  type_idx = 0
  while type_idx < FLAG_TYPES.length
    type = FLAG_TYPES[type_idx]
    size_idx = 0
    while size_idx < 2
      large = (size_idx == 1)
      base_w = large ? FLAG_LARGE_BASE_W : FLAG_SMALL_BASE_W
      flag_h = large ? FLAG_LARGE_FLAG_H : FLAG_SMALL_FLAG_H
      sw     = large ? FLAG_LARGE_W : FLAG_SMALL_W
      sh     = large ? FLAG_LARGE_H : FLAG_SMALL_H
      wave_idx = 0
      while wave_idx < 4
        sprite = p5.create_graphics(sw, sh)
        render_flag_to_sprite(sprite, type, base_w, flag_h, FLAG_WAVE[wave_idx])
        sprites << sprite
        wave_idx += 1
      end
      size_idx += 1
    end
    type_idx += 1
  end
  sprites
end

def draw_battle_flag(p5, fx, frame, idx, type_idx, size)
  large = (size == :large)
  flag_h = large ? FLAG_LARGE_FLAG_H : FLAG_SMALL_FLAG_H
  top_y = GROUND_Y - flag_h - 2
  size_idx = large ? 1 : 0
  wave_idx = (frame / 6 + idx) & 3
  sprite = FLAG_SPRITES[type_idx * 8 + size_idx * 4 + wave_idx]
  # Sprite origin (sprite x=0, y=0) maps to (fx - 2, top_y - 2) on screen.
  p5.blit(sprite, fx - 2, top_y - 2, TRANS_KEY)
end

def draw_battle_flags(p5, bg_offset, frame)
  off = bg_offset / PARALLAX_FLAG
  right_limit = W + 16
  i = 0
  while i < SEKI_FLAGS.length
    f = SEKI_FLAGS[i]
    sx = f[0] - off
    break if sx > right_limit
    if sx > -16
      draw_battle_flag(p5, sx, frame, i, f[1], f[2])
    end
    i += 1
  end
end

# ===== Mt. Fuji (single instance, drifts past slowly) =====

# Draw a mirrored trapezoid stack centered at cx, walking through `points`
# (right-half outline). Each pair of consecutive points defines one band of
# trapezoid filled with `color`.
def draw_fuji_segments(p5, cx, points, color, base_y)
  p5.fill(color)
  i = 0
  while i < points.length - 1
    p1 = points[i]
    p2 = points[i + 1]
    top_y = base_y + p1[0]
    bot_y = base_y + p2[0]
    hw_top = p1[1]
    hw_bot = p2[1]
    p5.triangle(cx - hw_top, top_y, cx + hw_top, top_y, cx + hw_bot, bot_y)
    p5.triangle(cx - hw_top, top_y, cx - hw_bot, bot_y, cx + hw_bot, bot_y)
    i += 1
  end
end

def draw_fuji_at(p5, cx)
  base_y = HORIZON_Y
  p5.no_stroke

  # === Body (multi-segment trapezoid for a smooth Fuji curve) ===
  draw_fuji_segments(p5, cx, FUJI_BODY_POINTS, FUJI_BODY, base_y)

  # === Right-side shadow (eastern slope, in shade in the morning) ===
  p5.fill(FUJI_SHAD)
  i = 0
  while i < FUJI_BODY_POINTS.length - 1
    p1 = FUJI_BODY_POINTS[i]
    p2 = FUJI_BODY_POINTS[i + 1]
    top_y = base_y + p1[0]
    bot_y = base_y + p2[0]
    # Shade the right ~60% of each band.
    hw_top_inner = p1[1] / 4
    hw_bot_inner = p2[1] / 4
    p5.triangle(cx + hw_top_inner, top_y, cx + p1[1], top_y, cx + p2[1], bot_y)
    p5.triangle(cx + hw_top_inner, top_y, cx + hw_bot_inner, bot_y, cx + p2[1], bot_y)
    i += 1
  end

  # === Snow cap (follows mountain outline so no edge gap) ===
  draw_fuji_segments(p5, cx, FUJI_SNOW_POINTS, SNOW_CAP, base_y)

  # === Snow tongues hanging past the cap edge ===
  p5.fill(SNOW_CAP)
  snowline_y = base_y - 62
  i = 0
  while i < FUJI_SNOW_FINGERS.length
    f = FUJI_SNOW_FINGERS[i]
    bx = cx + f[0]
    hw = f[1]
    len = f[2]
    p5.triangle(bx - hw, snowline_y, bx + hw, snowline_y, bx, snowline_y + len)
    i += 1
  end

  # === Snow folds (subtle blue-tinged shading lines suggesting depth) ===
  p5.fill(SNOW_SHADE)
  p5.triangle(cx - 5, base_y - 86, cx - 1, base_y - 86, cx - 3, base_y - 74)
  p5.triangle(cx + 4, base_y - 84, cx + 8, base_y - 84, cx + 6, base_y - 72)
  p5.triangle(cx - 11, base_y - 80, cx - 8, base_y - 80, cx - 9, base_y - 70)

  # === Flat summit highlight ===
  p5.fill(SNOW_CAP)
  p5.rect(cx - 10, base_y - 93, 21, 1)
  p5.fill(FUJI_NAVY)
  p5.rect(cx - 3, base_y - 93, 6, 1)
end

def draw_fuji_if_visible(p5, bg_offset)
  sx = FUJI_WORLD_X - bg_offset / PARALLAX_FUJI
  if sx > -140 && sx < W + 140
    draw_fuji_at(p5, sx)
  end
end

# Companion mountains that scroll with Fuji so the surrounding landscape
# feels coherent rather than Fuji-only.
def draw_fuji_range(p5, bg_offset)
  off = bg_offset / PARALLAX_FUJI
  fuji_sx = FUJI_WORLD_X - off
  return if fuji_sx < -260 || fuji_sx > W + 260
  i = 0
  while i < FUJI_RANGE_MOUNTAINS.length
    m = FUJI_RANGE_MOUNTAINS[i]
    sx = fuji_sx + m[0]
    if sx > -40 && sx < W + 40
      draw_mountain(p5, sx, HORIZON_Y - m[1], 28, MID_MTN, NEAR_MTN, nil)
    end
    i += 1
  end
end

# ===== Tokyo Tower (behind buildings, slow parallax) =====

def draw_tokyo_tower_at(p5, cx)
  # Main truss in red, painted bands
  base_y = HORIZON_Y
  apex_y = base_y - 92
  p5.no_stroke
  p5.fill(TOWER_RED)
  p5.triangle(cx - 14, base_y, cx + 14, base_y, cx, apex_y)
  # Internal cross bracing
  p5.fill(BLACK)
  p5.rect(cx - 12, base_y - 18, 24, 1)
  p5.rect(cx - 9, base_y - 36, 18, 1)
  p5.rect(cx - 6, base_y - 56, 12, 1)
  # Observation deck (white band)
  p5.fill(WHITE)
  p5.rect(cx - 10, base_y - 42, 20, 3)
  p5.fill(TOWER_RED)
  p5.rect(cx - 10, base_y - 42, 20, 1)
  # Antenna mast
  p5.fill(TOWER_RED)
  p5.rect(cx - 1, base_y - 102, 2, 12)
  p5.fill(BRASS_LITE)
  p5.rect(cx - 1, base_y - 104, 2, 2)
end

def draw_tokyo_tower_if_visible(p5, bg_offset)
  sx = TOWER_WORLD_X - bg_offset / PARALLAX_TOWER
  if sx > -30 && sx < W + 30
    draw_tokyo_tower_at(p5, sx)
  end
end

# ===== Tokyo buildings =====

def draw_building(p5, bx, h, bw, color_id, idx)
  by = HORIZON_Y - h
  color = case color_id
          when 0 then BUILD_A
          when 1 then BUILD_B
          else BUILD_C
          end
  p5.no_stroke
  p5.fill(color)
  p5.rect(bx, by, bw, h)
  # Windows simplified to one horizontal lit strip per floor. From this
  # viewing distance (320x240 scene), per-window 2x2 rects look like noise;
  # a line per floor reads naturally as a far-away tower. Cuts ~40-100
  # rects per building down to ~10-20.
  p5.fill(WINDOW_DAY)
  wy = by + 4
  while wy < HORIZON_Y - 4
    p5.rect(bx + 2, wy, bw - 4, 1)
    wy += 5
  end
  # Roof line
  p5.fill(LOCO_BLACK)
  p5.rect(bx, by, bw, 1)
  # Neon sign on some buildings
  if (idx & 5) == 1
    p5.fill(NEON_PINK)
    p5.rect(bx + bw / 2 - 1, by - 4, 2, 4)
  end
end

def draw_tokyo_buildings(p5, bg_offset)
  off = bg_offset / PARALLAX_BUILD
  right_limit = W + 40
  i = 0
  while i < TOKYO_BUILDINGS.length
    b = TOKYO_BUILDINGS[i]
    sx = b[0] - off
    break if sx > right_limit
    if sx > -40
      draw_building(p5, sx, b[1], b[2], b[3], i)
    end
    i += 1
  end
end

# ===== Ground / rails =====

def draw_ground(p5)
  p5.no_stroke
  # Horizon haze
  p5.fill(GROUND_SKY)
  p5.rect(0, HORIZON_Y, W, GROUND_Y - HORIZON_Y)
  # Lit grass strip near the horizon
  p5.fill(GRASS_LITE)
  p5.rect(0, GROUND_Y, W, 4)
  # Main grass band
  p5.fill(GRASS)
  p5.rect(0, GROUND_Y + 4, W, 14)
  # Dark grass / foreground extends to the bottom of the screen so the area
  # below the rails is grass, not bare black.
  p5.fill(GRASS_DARK)
  p5.rect(0, GROUND_Y + 18, W, H - GROUND_Y - 18)
end

RAIL_TIE_PERIOD = 14
RAIL_SPRITE_W = W + RAIL_TIE_PERIOD
RAIL_SPRITE_H = 10

# Pre-render the rails as a horizontal strip wider than the screen by one
# tie period, so blitting it shifted by -(bg_offset % 14) covers the visible
# area without seams. Contains: gravel base, ties, dark+lit rail lines.
def build_rails_sprite(p5)
  sprite = p5.create_graphics(RAIL_SPRITE_W, RAIL_SPRITE_H)
  sprite.no_stroke
  sprite.fill(GRAVEL)
  sprite.rect(0, 0, RAIL_SPRITE_W, RAIL_SPRITE_H)
  sprite.fill(TIE)
  x = 0
  while x < RAIL_SPRITE_W
    sprite.rect(x, 3, 9, 5)
    x += RAIL_TIE_PERIOD
  end
  sprite.fill(RAIL_DARK)
  sprite.rect(0, 3, RAIL_SPRITE_W, 2)
  sprite.fill(LOCO_LITE)
  sprite.rect(0, 3, RAIL_SPRITE_W, 1)
  sprite.fill(RAIL_DARK)
  sprite.rect(0, 8, RAIL_SPRITE_W, 2)
  sprite
end

def draw_rails(p5, bg_offset)
  tie_off = bg_offset % RAIL_TIE_PERIOD
  p5.blit(RAILS_SPRITE, -tie_off, RAIL_Y - 3)
end

# ===== Smoke particles =====

def spawn_smoke(particles, index, x, y, hot)
  particles[index] = [x.to_f, y.to_f, 2.5, 0, hot ? 1 : 0]
end

def update_smoke_particles(particles, speed)
  i = 0
  while i < particles.length
    pp = particles[i]
    if pp
      pp[0] -= speed * 0.7
      pp[1] -= 0.9
      pp[2] += 0.35
      pp[3] += 1
      if pp[3] > 32 || pp[0] < -20 || pp[1] < 0
        particles[i] = nil
      end
    end
    i += 1
  end
end

def draw_smoke_particles(p5, particles)
  p5.no_stroke
  i = 0
  while i < particles.length
    pp = particles[i]
    if pp
      age = pp[3]
      hot = pp[4] == 1
      col = if age < 6 && hot
              FIRE_ORG
            elsif age < 10
              SMOKE_DK
            elsif age < 20
              SMOKE_MID
            else
              SMOKE_LT
            end
      px = pp[0].to_i
      py = pp[1].to_i
      r = pp[2].to_i
      p5.fill(col)
      p5.circle(px, py, r)
      if age > 8 && r > 3
        p5.fill(STEAM_LT)
        p5.circle(px - 1, py - 1, r / 2)
      end
    end
    i += 1
  end
end

# ===== Wheel =====

def draw_wheel(p5, cx, cy, r, phase)
  p5.no_stroke
  # Outer flange (red rim)
  p5.fill(LOCO_RED)
  p5.circle(cx, cy, r + 1)
  # Tire (dark)
  p5.fill(LOCO_BLACK)
  p5.circle(cx, cy, r)
  # Disc face
  p5.fill(LOCO_BODY)
  p5.circle(cx, cy, r - 2)
  # Spokes (4) radiating from hub
  spokes = WHEEL_SPOKES[phase & 7]
  p5.stroke(LOCO_LITE)
  p5.stroke_weight(1)
  scale_n = r - 2
  i = 0
  while i < 4
    dx = spokes[i * 2] * scale_n / 6
    dy = spokes[i * 2 + 1] * scale_n / 6
    p5.line(cx, cy, cx + dx, cy + dy)
    i += 1
  end
  p5.no_stroke
  # Hub
  p5.fill(LOCO_LITE)
  p5.circle(cx, cy, 2)
  p5.fill(LOCO_BLACK)
  p5.circle(cx, cy, 1)
end

# Pre-rendered wheel sprites. Each radius gets 8 phase variants (one per
# WHEEL_SPOKES position). Sprite size is (2r+3) x (2r+3) to enclose the rim
# circle of radius r+1; the wheel center sits at sprite (r+1, r+1).
def build_wheel_sprites(p5, r)
  sprites = []
  size = 2 * r + 3
  center = r + 1
  phase = 0
  while phase < 8
    sprite = p5.create_graphics(size, size)
    sprite.background(TRANS_KEY)
    draw_wheel(sprite, center, center, r, phase)
    sprites << sprite
    phase += 1
  end
  sprites
end

# Blit the pre-rendered wheel sprite for the given (r, phase) at world
# (cx, cy). Replaces the per-frame draw_wheel call.
def blit_wheel(p5, sprites, cx, cy, r, phase)
  p5.blit(sprites[phase & 7], cx - (r + 1), cy - (r + 1), TRANS_KEY)
end

# ===== Tender (coal car) =====

def draw_tender(p5, cx, cy, phase, body_only: false)
  body_top = cy - 12
  body_bot = cy + 8
  left = cx - 22
  right = cx + 22
  # Body
  p5.no_stroke
  p5.fill(LOCO_BLACK)
  p5.rect(left, body_top + 1, 44, body_bot - body_top)
  p5.fill(LOCO_BODY)
  p5.rect(left, body_top, 44, body_bot - body_top - 1)
  p5.fill(LOCO_LITE)
  p5.rect(left, body_top, 44, 1)
  # Side rivets
  p5.fill(LOCO_RIVET)
  i = 0
  while i < 5
    p5.rect(left + 4 + i * 9, body_top + 3, 1, 1)
    p5.rect(left + 4 + i * 9, body_bot - 4, 1, 1)
    i += 1
  end
  # Lower frame
  p5.fill(LOCO_BLACK)
  p5.rect(left - 2, body_bot - 2, 48, 4)
  # Coal mound
  p5.fill(COAL_DARK)
  p5.rect(left + 2, body_top - 3, 40, 3)
  p5.fill(COAL_BLK)
  coal = [3, 8, 14, 20, 27, 33, 38]
  i = 0
  while i < coal.length
    nx = left + coal[i]
    ny = body_top - 4 - ((i * 7 + phase) & 1)
    p5.rect(nx, ny, 3, 2)
    i += 1
  end
  p5.fill(COAL_HI)
  p5.rect(left + 6, body_top - 4, 1, 1)
  p5.rect(left + 20, body_top - 5, 1, 1)
  p5.rect(left + 34, body_top - 4, 1, 1)
  # Wheels (two truck wheels under tender). Skipped in body_only mode so
  # the sprite version doesn't bake the wheels in.
  unless body_only
    draw_wheel(p5, cx - 13, cy + 14, 6, phase)
    draw_wheel(p5, cx + 13, cy + 14, 6, phase + 3)
  end
  # Rear-side ladder (on the back / left side of tender)
  p5.fill(LOCO_LITE)
  p5.rect(left + 1, body_top + 2, 1, 14)
  p5.rect(left + 1, body_top + 6, 4, 1)
  p5.rect(left + 1, body_top + 10, 4, 1)
end

def draw_tender_wheels(p5, cx, cy, phase)
  blit_wheel(p5, WHEEL_R6_SPRITES, cx - 13, cy + 14, 6, phase)
  blit_wheel(p5, WHEEL_R6_SPRITES, cx + 13, cy + 14, 6, phase + 3)
end

# ===== Locomotive =====

def draw_locomotive(p5, base_x, base_y, wheel_phase, frame, body_only: false)
  bx = base_x
  by = base_y

  # Running board / footplate
  p5.no_stroke
  p5.fill(LOCO_BLACK)
  p5.rect(bx - 44, by + 6, 80, 4)
  p5.fill(LOCO_BODY)
  p5.rect(bx - 44, by + 6, 80, 1)

  # === Boiler ===
  p5.fill(LOCO_BLACK)
  p5.rect(bx - 36, by - 8, 66, 16)
  p5.fill(LOCO_BODY)
  p5.rect(bx - 36, by - 9, 66, 15)
  p5.fill(LOCO_LITE)
  p5.rect(bx - 36, by - 9, 66, 2)
  # Boiler bands
  p5.fill(LOCO_BLACK)
  p5.rect(bx - 18, by - 9, 1, 17)
  p5.rect(bx, by - 9, 1, 17)
  p5.rect(bx + 16, by - 9, 1, 17)
  p5.fill(BRASS)
  p5.rect(bx - 17, by - 9, 1, 17)
  p5.rect(bx + 1, by - 9, 1, 17)
  p5.rect(bx + 17, by - 9, 1, 17)

  # === Smoke box (front) ===
  p5.fill(LOCO_BLACK)
  p5.rect(bx + 30, by - 12, 6, 22)
  p5.fill(LOCO_BODY)
  p5.circle(bx + 33, by - 1, 9)
  # Smoke box door wheel
  p5.fill(BRASS_LITE)
  p5.rect(bx + 30, by - 1, 7, 1)
  p5.rect(bx + 33, by - 4, 1, 7)
  p5.fill(BRASS)
  p5.circle(bx + 33, by - 1, 2)

  # === Headlight ===
  p5.fill(LOCO_BLACK)
  p5.rect(bx + 36, by - 8, 5, 7)
  p5.fill(WINDOW_LIT)
  p5.rect(bx + 37, by - 7, 3, 5)
  p5.fill(SUN_CORE)
  p5.rect(bx + 38, by - 6, 1, 3)

  # === Chimney ===
  p5.fill(LOCO_BLACK)
  p5.rect(bx + 22, by - 24, 6, 15)
  p5.fill(LOCO_BODY)
  p5.rect(bx + 22, by - 22, 1, 13)
  # Cap (wider)
  p5.fill(LOCO_BLACK)
  p5.rect(bx + 20, by - 26, 10, 3)
  p5.fill(LOCO_LITE)
  p5.rect(bx + 21, by - 26, 8, 1)

  # === Steam dome ===
  p5.fill(LOCO_BODY)
  p5.rect(bx + 4, by - 16, 9, 7)
  p5.fill(LOCO_LITE)
  p5.rect(bx + 4, by - 18, 9, 2)
  p5.fill(BRASS_LITE)
  p5.rect(bx + 5, by - 19, 7, 1)

  # === Sand dome ===
  p5.fill(LOCO_BODY)
  p5.rect(bx - 12, by - 14, 7, 5)
  p5.fill(LOCO_LITE)
  p5.rect(bx - 12, by - 15, 7, 1)

  # === Bell ===
  p5.fill(BRASS)
  p5.rect(bx + 14, by - 13, 3, 4)
  p5.rect(bx + 13, by - 11, 5, 1)
  p5.fill(BRASS_LITE)
  p5.rect(bx + 14, by - 13, 1, 3)

  # === Whistle ===
  p5.fill(LOCO_LITE)
  p5.rect(bx - 4, by - 14, 1, 4)
  p5.fill(BRASS_LITE)
  p5.rect(bx - 5, by - 15, 3, 1)

  # === Hand rail along the boiler ===
  p5.stroke(LOCO_LITE)
  p5.stroke_weight(1)
  p5.line(bx - 30, by - 6, bx + 28, by - 6)
  p5.no_stroke

  # === Cab ===
  cab_left = bx - 50
  cab_top = by - 18
  cab_right = bx - 32
  cab_bottom = by + 6
  p5.fill(LOCO_BLACK)
  p5.rect(cab_left - 1, cab_top, cab_right - cab_left + 2, cab_bottom - cab_top + 1)
  p5.fill(LOCO_BODY)
  p5.rect(cab_left, cab_top + 1, cab_right - cab_left, cab_bottom - cab_top - 1)
  p5.fill(LOCO_LITE)
  p5.rect(cab_left, cab_top + 1, cab_right - cab_left, 1)
  # Roof overhang
  p5.fill(LOCO_BLACK)
  p5.rect(cab_left - 2, cab_top, cab_right - cab_left + 4, 2)
  p5.fill(LOCO_LITE)
  p5.rect(cab_left - 2, cab_top, cab_right - cab_left + 4, 1)
  # Window
  p5.fill(LOCO_BLACK)
  p5.rect(cab_left + 2, cab_top + 4, 14, 8)
  p5.fill(WINDOW_LIT)
  p5.rect(cab_left + 3, cab_top + 5, 12, 6)
  p5.fill(LOCO_BLACK)
  p5.rect(cab_left + 8, cab_top + 5, 1, 6)
  # Engineer silhouette in the cab window
  p5.fill(LOCO_RED)
  p5.rect(cab_left + 5, cab_top + 6, 2, 3)
  p5.fill(WINDOW_LIT)
  p5.rect(cab_left + 5, cab_top + 5, 2, 1)
  # Door rivets
  p5.fill(LOCO_RIVET)
  p5.rect(cab_right - 2, cab_top + 4, 1, 1)
  p5.rect(cab_right - 2, cab_top + 8, 1, 1)
  p5.rect(cab_right - 2, cab_top + 12, 1, 1)

  # === Cylinder ===
  p5.fill(LOCO_BLACK)
  p5.rect(bx + 16, by + 8, 12, 8)
  p5.fill(LOCO_BODY)
  p5.rect(bx + 16, by + 8, 12, 1)
  p5.fill(LOCO_LITE)
  p5.rect(bx + 16, by + 8, 12, 1)
  p5.fill(BRASS)
  p5.rect(bx + 26, by + 10, 2, 4)

  # === Pilot / cow catcher ===
  p5.fill(LOCO_BLACK)
  p5.triangle(bx + 36, by + 6, bx + 42, by + 6, bx + 38, by + 16)
  p5.stroke(LOCO_LITE)
  p5.line(bx + 36, by + 8, bx + 39, by + 16)
  p5.line(bx + 38, by + 6, bx + 39, by + 14)
  p5.line(bx + 40, by + 6, bx + 40, by + 12)
  p5.no_stroke

  # === Front buffer beam ===
  p5.fill(LOCO_DARKRED)
  p5.rect(bx + 32, by + 10, 6, 4)
  p5.fill(LOCO_RED)
  p5.rect(bx + 32, by + 10, 6, 1)
  p5.fill(LOCO_BLACK)
  p5.rect(bx + 35, by + 14, 2, 3)

  # === Piston rod from cylinder to driver (static position) ===
  p5.fill(LOCO_LITE)
  p5.rect(bx + 14, by + 12, 14, 2)

  # === Coupling to tender (rear) ===
  p5.fill(LOCO_BLACK)
  p5.rect(bx - 65, by + 8, 15, 3)

  # === Tender body (wheels handled by draw_locomotive_motion) ===
  draw_tender(p5, tender_x_from_loco(base_x), by, wheel_phase, body_only: body_only)

  # === Drive wheels + side rod (dynamic, skipped when prerendering) ===
  unless body_only
    draw_locomotive_motion(p5, base_x, base_y, wheel_phase)
  end
end

# TENDER_X is a screen-space constant for runtime use, but when prerendering
# the locomotive into a sprite the tender needs to sit at the same offset
# relative to the locomotive's base_x as it does at runtime. Computes the
# tender center given the locomotive base_x.
TENDER_OFFSET_FROM_LOCO = TENDER_X - LOCO_X
def tender_x_from_loco(base_x)
  base_x + TENDER_OFFSET_FROM_LOCO
end

# Dynamic parts of the locomotive: drive wheels, pilot wheel, side rod, and
# the tender's wheels. Called every frame on top of the pre-rendered sprite.
def draw_locomotive_motion(p5, base_x, base_y, wheel_phase)
  bx = base_x
  by = base_y
  wheel_y = by + 16
  # Drive wheels spaced 20 apart so they don't overlap (radius 9 + 9 = 18 < 20).
  blit_wheel(p5, WHEEL_R9_SPRITES, bx - 26, wheel_y, 9, wheel_phase)
  blit_wheel(p5, WHEEL_R9_SPRITES, bx - 6,  wheel_y, 9, wheel_phase + 2)
  blit_wheel(p5, WHEEL_R9_SPRITES, bx + 14, wheel_y, 9, wheel_phase + 4)
  # Pilot wheel (smaller, in front under the cylinder)
  blit_wheel(p5, WHEEL_R5_SPRITES, bx + 30, wheel_y + 2, 5, wheel_phase + 1)
  # Side rod connecting drive wheels
  rod_dy = (wheel_phase & 1) == 0 ? 0 : 1
  p5.fill(LOCO_LITE)
  p5.rect(bx - 28, wheel_y - 1 + rod_dy, 44, 2)
  p5.fill(LOCO_BLACK)
  p5.rect(bx - 26, wheel_y + rod_dy, 1, 1)
  p5.rect(bx - 6,  wheel_y + rod_dy, 1, 1)
  p5.rect(bx + 14, wheel_y + rod_dy, 1, 1)
  # Tender wheels
  draw_tender_wheels(p5, tender_x_from_loco(bx), by, wheel_phase)
end

# Build the pre-rendered locomotive + tender body sprite. Done once at
# startup; the static result is then blitted every frame.
def build_locomotive_sprite(p5)
  sprite = p5.create_graphics(LOCO_SPRITE_W, LOCO_SPRITE_H)
  sprite.background(TRANS_KEY)
  draw_locomotive(sprite, LOCO_SPRITE_BX, LOCO_SPRITE_BY, 0, 0, body_only: true)
  sprite
end

# Blit the pre-rendered sprite + draw the wheels/rod on top. Replaces the
# per-frame draw_locomotive call.
def draw_train_sprite(p5, sprite, base_x, base_y, wheel_phase)
  p5.blit(sprite, base_x - LOCO_SPRITE_BX, base_y - LOCO_SPRITE_BY, TRANS_KEY)
  draw_locomotive_motion(p5, base_x, base_y, wheel_phase)
end

# ===== Ruby-chan (the runner chasing the locomotive) =====
#
# 16x16 sprite, one character per pixel:
#   . = transparent
#   R = body red          (#E60012 -> RUBY_RED)
#   B = black             (#1A1A1A -> BLACK)
#   W = white highlight   (#FFFFFF -> WHITE)
#   P = pink cheek        (#F09595 -> RUBY_BLUSH)
# Rows 0..13 are the body (solid red apple silhouette with face). Rows 14
# and 15 are the feet, drawn separately so they can be animated.
RUBY_PIXEL_DATA = [
  "....RRRRRRRR....",
  "...RRRRRRRRRR...",
  "..RWRRRRRRRRWR..",
  ".RRRRRRRRRRRRRR.",
  ".RRRWBRRRRWBRRR.",
  ".RRRBBRRRRBBRRR.",
  ".RPPRRRRRRRRPPR.",
  ".RRRRRBRRBRRRRR.",
  ".RRRRRRBBRRRRRR.",
  "..RRRRRRRRRRRR..",
  "...RRRRRRRRRR...",
  "....RRRRRRRR....",
  ".....RRRRRR.....",
  "......RRRR......",
]

def ruby_pixel_color(ch)
  case ch
  when "R" then RUBY_RED
  when "B" then BLACK
  when "W" then WHITE
  when "P" then RUBY_BLUSH
  else nil
  end
end

RUBY_SPRITE_W = 16
RUBY_SPRITE_H = RUBY_PIXEL_DATA.length

def build_ruby_sprite(p5)
  sprite = p5.create_graphics(RUBY_SPRITE_W, RUBY_SPRITE_H)
  sprite.background(TRANS_KEY)
  sprite.no_stroke
  y = 0
  while y < RUBY_PIXEL_DATA.length
    row = RUBY_PIXEL_DATA[y]
    x = 0
    while x < row.length
      ch = row[x, 1]
      if ch == "."
        x += 1
      else
        run_start = x
        while x < row.length && row[x, 1] == ch
          x += 1
        end
        col = ruby_pixel_color(ch)
        if col
          sprite.fill(col)
          sprite.rect(run_start, y, x - run_start, 1)
        end
      end
    end
    y += 1
  end
  sprite
end

def draw_ruby_runner(p5, cx, base_y, frame, speed)
  # Run cycle: phase 0/2 = one foot lifted (body at peak), phase 1/3 = both
  # feet planted (body at bottom). bob_div scales the cycle with speed.
  bob_div = if speed > 3.0
              3
            elsif speed > 1.0
              4
            else
              7
            end
  bob_phase = (frame / bob_div) & 3
  bob = (bob_phase & 1 == 0) ? 2 : 0

  # Body sprite is 16 wide x 14 tall (rows 0..13). base_y is where the
  # feet's bottom lands; feet add 2 more rows below the sprite.
  top_y = base_y - 16 - bob
  left_x = cx - 8

  # Blit the pre-rendered body sprite (saves ~38 rect calls per frame).
  p5.blit(RUBY_SPRITE, left_x, top_y, TRANS_KEY)
  p5.no_stroke

  # Feet at rows 14..15 of the sprite. Left foot at cols 4..6, right at
  # cols 9..11. Alternate which foot is fully planted (2 tall) vs lifted
  # (1 tall) for the running animation.
  leg_phase = (frame / bob_div) & 3
  left_h, right_h = case leg_phase
                    when 0 then [1, 2]
                    when 2 then [2, 1]
                    else        [2, 2]
                    end
  p5.fill(BLACK)
  p5.rect(left_x + 4, top_y + 14, 3, left_h)
  p5.rect(left_x + 9, top_y + 14, 3, right_h)

  # Speed lines trailing behind when sprinting.
  if speed > 1.2
    p5.fill(SMOKE_LT)
    p5.rect(cx - 14, top_y + 5,  4, 1)
    p5.rect(cx - 16, top_y + 8,  5, 1)
    p5.rect(cx - 13, top_y + 11, 3, 1)
  end
end

# ===== Combined scene draw =====
#
# Layer order (back to front):
#   sky → clouds → sun → far mountains → mid mountains → Fuji
#   → near mountains → Tokyo Tower → Tokyo buildings → ground
#   → trees → flags → rails
#
# Every element lives at a world_x; bg_offset moves the whole world to the
# left. As bg_offset grows, Sekigahara peaks drift off, Fuji slides in from
# the right and back out left, then Tokyo Tower and buildings come in.
def draw_scene(p5, bg_offset, frame)
  draw_sky(p5)
  draw_clouds(p5, bg_offset)
  draw_sun(p5)
  draw_far_mountains(p5, bg_offset)
  draw_mid_mountains(p5, bg_offset)
  draw_fuji_if_visible(p5, bg_offset)
  draw_fuji_range(p5, bg_offset)
  draw_near_mountains(p5, bg_offset)
  draw_tokyo_tower_if_visible(p5, bg_offset)
  draw_tokyo_buildings(p5, bg_offset)
  draw_ground(p5)
  draw_trees(p5, bg_offset)
  draw_battle_flags(p5, bg_offset, frame)
  draw_rails(p5, bg_offset)
end

# ===== HUD / overlays =====

def draw_hud(p5, remaining_ms, total_ms, phase_text)
  p5.no_stroke
  p5.fill(BLACK)
  p5.rect(0, 0, W, HUD_H)
  p5.fill(LOCO_RED)
  p5.rect(0, HUD_H - 1, W, 1)
  p5.text_font(DVI::Graphics::FONT_MPLUS_12)
  p5.text_color(WHITE)
  p5.text_align(:left, :top)
  p5.text(fmt_time(remaining_ms), 4, 3)
  if phase_text
    p5.text_color(BRASS_LITE)
    p5.text_align(:right, :top)
    p5.text(phase_text, W - 4, 3)
    p5.text_align(:left, :top)
  end
end

def draw_opening_screen(p5, frame, bg_offset, wheel_phase, total_seconds)
  draw_scene(p5, bg_offset, frame)
  draw_train_sprite(p5, LOCO_SPRITE, LOCO_X, LOCO_Y, wheel_phase)

  # Title overlay
  p5.no_stroke
  p5.fill(BLACK)
  p5.rect(20, 24, W - 40, 70)
  p5.fill(LOCO_RED)
  p5.rect(20, 24, W - 40, 2)
  p5.rect(20, 92, W - 40, 2)

  p5.text_font(DVI::Graphics::FONT_MPLUS_12)
  p5.text_align(:center, :top)
  p5.text_color(BRASS_LITE)
  p5.text("makicamel", W / 2, 30)
  p5.text_color(WHITE)
  p5.text("RubyKaja 2026 SPECIAL AWARD", W / 2, 50)
  p5.text_color(SUN_CORE)
  p5.text("from PicoPicoRuby", W / 2, 70)
  p5.text_color(SUN_CORE)
  p5.text("Timer: #{total_seconds}s  1:150 / 2:60 / 3:30", W / 2, 8)
  p5.text_color(WHITE)
  p5.text("Powered by Harucom", W / 2, 208)
  p5.text("(c) 2026 harukasan", W / 2, 222)
  if (frame / 20) & 1 == 0
    p5.text_color(BRASS_LITE)
    p5.text("Press SPACE", W / 2, 156)
  end
  p5.text_align(:left, :top)
end

def draw_big_centered(p5, str, color, scale = 1)
  p5.text_font(DVI::Graphics::FONT_MPLUS_12)
  p5.text_color(color)
  p5.text_align(:center, :center)
  if scale > 1
    p5.push_matrix
    p5.translate(W / 2, H / 3)
    p5.scale(scale, scale)
    p5.text(str, 0, 0)
    p5.pop_matrix
  else
    p5.text(str, W / 2, H / 3)
  end
  p5.text_align(:left, :top)
end

def draw_ending_announcement(p5, elapsed_ms, bg_offset, frame, wheel_phase)
  draw_scene(p5, bg_offset, frame)
  draw_train_sprite(p5, LOCO_SPRITE, LOCO_X, LOCO_Y, wheel_phase)
  p5.no_stroke
  p5.fill(BLACK)
  p5.rect(24, 36, W - 48, 110)
  p5.fill(LOCO_RED)
  p5.rect(24, 36, W - 48, 2)
  p5.rect(24, 144, W - 48, 2)
  p5.rect(24, 36, 2, 110)
  p5.rect(W - 26, 36, 2, 110)
  p5.fill(BRASS)
  p5.rect(28, 42, W - 56, 1)
  p5.rect(28, 139, W - 56, 1)

  p5.text_font(DVI::Graphics::FONT_MPLUS_12)
  p5.text_align(:center, :top)
  p5.text_color(BRASS_LITE)
  p5.text("PicoRubyKaigi 2026 Assemble", W / 2, 52)
  p5.text_color(SUN_CORE)
  p5.text("2026.10.31", W / 2, 78)
  p5.text_color(WHITE)
  p5.text("at Akihabara", W / 2, 100)
  p5.text_color(BRASS_LITE)
  p5.text("https://picorubykaigi.org/", W / 2, 122)
  if (frame / 20) & 1 == 0
    p5.text_color(BRASS_LITE)
    p5.text("Press SPACE", W / 2, 156)
  end
  p5.text_align(:left, :top)
end

def draw_explosion(p5, elapsed_ms, bg_offset)
  t = elapsed_ms.to_f / 1000.0
  draw_sky(p5)
  draw_clouds(p5, bg_offset)
  draw_ground(p5)
  draw_rails(p5, bg_offset)
  cx = LOCO_X
  cy = LOCO_Y - 6
  # Orange is the outermost layer and grows fast enough to engulf the
  # whole screen (~diag 200 px) by the mid-explosion mark. Yellow and red
  # stay smaller so the fireball reads as a layered hot core inside an
  # orange flash.
  r_org = 20 + (t * 220).to_i
  r_ylw = 12 + (t * 90).to_i
  r_red = 6 + (t * 50).to_i
  p5.no_stroke
  p5.fill(FIRE_ORG)
  p5.circle(cx, cy, r_org)
  p5.fill(FIRE_YLW)
  p5.circle(cx, cy, r_ylw)
  p5.fill(FIRE_RED)
  p5.circle(cx, cy, r_red)
  p5.fill(WHITE)
  p5.circle(cx, cy, r_red / 3)
  i = 0
  while i < 14
    angle_idx = i & 7
    spread = (t * 90).to_i + i * 3
    dx = WHEEL_SPOKES[angle_idx][0] * spread / 6
    dy = WHEEL_SPOKES[angle_idx][1] * spread / 6
    px = cx + dx
    py = cy + dy - (t * 12).to_i
    p5.fill((i & 1 == 0) ? LOCO_BLACK : LOCO_BODY)
    p5.rect(px, py, 3, 3)
    i += 1
  end
  i = 0
  while i < 8
    sx = cx - 24 + i * 6
    sy = cy - 24 - (t * 12).to_i + (i & 1) * 2
    sr = 8 + (i % 3)
    p5.fill(SMOKE_DK)
    p5.circle(sx, sy, sr)
    p5.fill(SMOKE_MID)
    p5.circle(sx - 1, sy - 1, sr - 2)
    i += 1
  end
  draw_big_centered(p5, "BOOM!", FIRE_RED, 2)
end

# Pre-render the static parts of the locomotive into a sprite. The result is
# blitted each frame, with only the wheels and side rod redrawn dynamically.
LOCO_SPRITE = build_locomotive_sprite(p5)

# Pre-render the 10 battle flag sprites (5 types x 2 sizes). Each flag is
# blitted once per frame; only the wave trailing-edge rects are drawn live.
FLAG_SPRITES = build_flag_sprites(p5)

# Pre-render the two tree variants (pine, round) into sprites.
TREE_SPRITES = build_tree_sprites(p5)
PINE_SPRITE  = TREE_SPRITES[0]
ROUND_SPRITE = TREE_SPRITES[1]

# Pre-render Ruby-chan's body (rows 0..13). Feet rows are drawn live for the
# run-cycle animation.
RUBY_SPRITE = build_ruby_sprite(p5)

# Pre-render the entire rail strip as a sprite that's one tie-period wider
# than the screen. Each frame just blits it once at a scrolled offset.
RAILS_SPRITE = build_rails_sprite(p5)

# Pre-render 3 height buckets per mountain layer (9 sprites total). Each
# layer's sprites use the layer's half_w and body/shadow color pair.
FAR_MTN_SPRITES  = build_mountain_sprites(p5, 26, FAR_MTN_BUCKETS,  FAR_MTN,  MID_MTN)
MID_MTN_SPRITES  = build_mountain_sprites(p5, 36, MID_MTN_BUCKETS,  MID_MTN,  NEAR_MTN)
NEAR_MTN_SPRITES = build_mountain_sprites(p5, 48, NEAR_MTN_BUCKETS, NEAR_MTN, LOCO_BLACK)

# Pre-rendered wheel sprites: 8 phase variants per radius. Drive wheels use
# r=9, pilot uses r=5, tender uses r=6. Each blit_wheel call becomes a
# single image() instead of ~17 draw calls.
WHEEL_R5_SPRITES = build_wheel_sprites(p5, 5)
WHEEL_R6_SPRITES = build_wheel_sprites(p5, 6)
WHEEL_R9_SPRITES = build_wheel_sprites(p5, 9)

# ===== Main loop =====

total_seconds = (ARGV[0] || "150").to_i
total_seconds = 150 if total_seconds <= 0
total_ms, warmup_ms, running_ms, journey_scale = derive_timer(total_seconds)

state = :opening
state_start_ms = Machine.board_millis
bg_offset = 0
# wheel_accum is the integer accumulator that drives wheel spoke phase.
# We advance it every frame based on speed so the rotation looks smooth
# instead of snapping between two positions.
wheel_accum = 0
frame = 0
smoke_particles = Array.new(14, nil)
smoke_timer = 0
smoke_index = 0
next_frame_ms = Machine.board_millis

prev_loop_ms = next_frame_ms

loop do
  now = Machine.board_millis
  elapsed = now - state_start_ms
  # Wall-clock delta scaled to target-frame units. At 30fps this is ~1.0;
  # at 10fps it's ~3.0. Per-frame counters (bg_offset, frame, wheel_accum,
  # smoke_timer) multiply by this so wall-clock pacing stays the same even
  # when the render rate drops. Clamp to 1 so an unexpectedly fast frame
  # never advances less than one target-frame's worth.
  dt_ms = now - prev_loop_ms
  prev_loop_ms = now
  dt_frames = dt_ms.to_f / FRAME_INTERVAL_MS
  dt_frames = 1.0 if dt_frames < 1.0
  enter, quit, preset = drain_input(keyboard)
  break if quit
  # Live timer preset (1/2/3). Apply immediately so the user sees the new
  # remaining time on the HUD; for in-flight races this also recomputes the
  # warmup/running split and the journey scroll scale.
  if preset && preset != total_seconds
    total_seconds = preset
    total_ms, warmup_ms, running_ms, journey_scale = derive_timer(total_seconds)
  end

  speed = speed_for(state, elapsed, warmup_ms, running_ms)

  # Background scroll: bg_offset only advances during warmup/running.
  # Opening uses a tiny drift to keep the locomotive idle but alive.
  if state == :warmup || state == :running
    bg_offset += ((speed * 2.8 + 1.0) * dt_frames * journey_scale).to_i
  elsif state == :opening
    bg_offset += (1 * dt_frames).to_i
  elsif state == :result_goal && elapsed > PHASE_RESULT_MS
    # Keep the train idling at Tokyo during the announcement
    bg_offset += (1 * dt_frames).to_i
  end

  # Wheel rotation: advance by an integer amount each frame so wheels spin
  # smoothly through all 8 spoke phases regardless of speed.
  spin_inc = case state
             when :warmup           then 2 + (speed * 4).to_i
             when :running          then 4 + (speed * 5).to_i
             when :result_goal      then (elapsed < PHASE_RESULT_MS ? 6 : 0)
             when :opening, :countdown, :start
               1
             else
               0
             end
  wheel_accum += (spin_inc * dt_frames).to_i
  wheel_accum -= 65_536 if wheel_accum > 65_536
  wheel_phase = (wheel_accum / 4) & 7

  # Smoke generation
  if state == :warmup || state == :running || state == :opening || state == :start
    smoke_rate = case state
                 when :opening then 1
                 when :start, :warmup then 3
                 else (3 + (speed * 2).to_i)
                 end
    smoke_timer += (smoke_rate * dt_frames).to_i
    if smoke_timer >= 60
      smoke_timer = 0
      hot = state == :running && (frame & 3) == 0
      spawn_smoke(smoke_particles, smoke_index, LOCO_X + 25, LOCO_Y - 28, hot)
      smoke_index = (smoke_index + 1) % smoke_particles.length
    end
    update_smoke_particles(smoke_particles, speed > 0.2 ? speed : 0.4)
  end

  case state
  when :opening
    draw_opening_screen(p5, frame, bg_offset, wheel_phase, total_seconds)
    draw_smoke_particles(p5, smoke_particles)
    if enter
      state = :countdown
      state_start_ms = now
    end

  when :countdown
    draw_scene(p5, bg_offset, frame)
    draw_train_sprite(p5, LOCO_SPRITE, LOCO_X, LOCO_Y, wheel_phase)
    draw_smoke_particles(p5, smoke_particles)
    seconds_left = 3 - (elapsed / 1000)
    seconds_left = 1 if seconds_left < 1
    draw_big_centered(p5, seconds_left.to_s, LOCO_RED, 3)
    if elapsed >= PHASE_COUNTDOWN_MS
      state = :start
      state_start_ms = now
    end

  when :start
    draw_scene(p5, bg_offset, frame)
    draw_train_sprite(p5, LOCO_SPRITE, LOCO_X, LOCO_Y, wheel_phase)
    draw_smoke_particles(p5, smoke_particles)
    draw_big_centered(p5, "START!", BRASS_LITE, 2)
    if elapsed >= PHASE_START_MS
      state = :warmup
      state_start_ms = now
    end

  when :warmup
    draw_scene(p5, bg_offset, frame)
    draw_train_sprite(p5, LOCO_SPRITE, LOCO_X, LOCO_Y, wheel_phase)
    draw_smoke_particles(p5, smoke_particles)
    remaining = total_ms - elapsed
    draw_hud(p5, remaining, total_ms, "GO!")
    if elapsed >= warmup_ms
      state = :running
      state_start_ms = now
    end
    if enter
      state = :result_goal
      state_start_ms = now
    end

  when :running
    draw_scene(p5, bg_offset, frame)
    draw_train_sprite(p5, LOCO_SPRITE, LOCO_X, LOCO_Y, wheel_phase)
    draw_smoke_particles(p5, smoke_particles)
    remaining = running_ms - elapsed
    draw_hud(p5, remaining, total_ms, "GO!")
    if enter
      state = :result_goal
      state_start_ms = now
    elsif elapsed >= running_ms
      state = :result_explode
      state_start_ms = now
    end

  when :result_goal
    if elapsed < PHASE_RESULT_MS
      draw_scene(p5, bg_offset, frame)
      draw_train_sprite(p5, LOCO_SPRITE, LOCO_X, LOCO_Y, wheel_phase)
      draw_smoke_particles(p5, smoke_particles)
      # Goal banner
      p5.no_stroke
      p5.fill(BRASS_LITE)
      p5.rect(LOCO_X - 1, LOCO_Y - 38, 14, 9)
      p5.fill(LOCO_RED)
      p5.text_font(DVI::Graphics::FONT_8X8)
      p5.text_color(LOCO_RED)
      p5.text_align(:center, :center)
      p5.text("GOAL", LOCO_X + 6, LOCO_Y - 34)
      draw_big_centered(p5, "GOAL!", BRASS_LITE, 2)
    else
      draw_ending_announcement(p5, elapsed - PHASE_RESULT_MS, bg_offset, frame, wheel_phase)
      if enter
        state = :opening
        state_start_ms = now
        bg_offset = 0
        wheel_accum = 0
        clear_smoke(smoke_particles)
      end
    end

  when :result_explode
    if elapsed < PHASE_RESULT_MS
      draw_explosion(p5, elapsed, bg_offset)
    else
      # After the boom settles, still show the PicoRubyKaigi announcement
      # so the audience always sees the closing slide.
      draw_ending_announcement(p5, elapsed - PHASE_RESULT_MS, bg_offset, frame, wheel_phase)
      if enter
        state = :opening
        state_start_ms = now
        bg_offset = 0
        wheel_accum = 0
        clear_smoke(smoke_particles)
      end
    end
  end

  # Ruby-chan runs below the rails chasing the locomotive in every state
  # except the explosion / standalone announcement screens.
  ruby_visible = case state
                 when :opening, :countdown, :start, :warmup, :running then true
                 when :result_goal then elapsed < PHASE_RESULT_MS
                 else false
                 end
  if ruby_visible
    ruby_speed = case state
                 when :opening, :countdown then 0.3
                 when :start               then 0.6
                 else speed
                 end
    draw_ruby_runner(p5, 42, 232, frame, ruby_speed)
  end

  p5.commit
  # Cap to ~30fps so frame intervals stay consistent rather than oscillating
  # between 16ms and 33ms. When rendering falls behind, frame counter scales
  # with wall-clock dt so animations stay at the same wall-clock pace.
  next_frame_ms += FRAME_INTERVAL_MS
  remaining = next_frame_ms - Machine.board_millis
  if remaining > 0
    sleep_ms(remaining)
  else
    # Drawing already exceeded one 30fps slot - reset the deadline so we
    # don't stack up debt for the next frame.
    next_frame_ms = Machine.board_millis
  end
  frame += (2 * dt_frames).to_i
end
