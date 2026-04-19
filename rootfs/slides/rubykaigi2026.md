---
title: Building a Standalone<br>Ruby Programming Environment
subtitle: April 22 2026, RubyKaigi 2026
author: Shunsuke Michii
theme: rubykaigi2026
allotted_time: 30
---

# Self Introduction

```p5_setup
bmp = PicoRabbit::BMP.load("/data/pixelcat.bmp")
ix = 640 - 60 - bmp.width
cx = ix + bmp.width / 2
cy = y + bmp.height / 2
```
```p5
angle = (DVI.frame_count % 360) * Math::PI / 180.0
p5.push_matrix
p5.translate(cx, cy)
p5.rotate(angle)
p5.image_masked(bmp.data, bmp.mask, -bmp.width / 2, -bmp.height / 2, bmp.width, bmp.height)
p5.pop_matrix
```
Shunsuke Michii
a.k.a **Harukasan**

* Software Engineer
* Electronics Hobbyist
* Also the CTO of Pixiv Inc.

# Harucom Board

- RP2350A (dual core ARM Cortex-M33, 520 KB SRAM)
- 16 MB Flash
- 8 MB PSRAM
- DVI output (640x480 @ 60Hz)
- USB keyboard input
- Audio output
- Grove connector

# Now available on BOOTH!

BOOTH: a marketplace for creative endeavors
Powered by Ruby on Rails

{::wait/}

We're hiring!

# PicoRabbit

A presentation tool inspired by Rabbit
**Rewritten as a Ruby application on Harucom**

- Markdown-based slides
- 640x480 rendering with anti-aliased fonts
- Bitmap image support
- Scriptable theme in Ruby

# Harucom OS

```p5_setup
# Stack diagram
rows = [
  [[0xE0, "Ruby Applications"]],
  [[0xA0, "Harucom OS"]],
  [[0x80, "PicoRuby"], [0x64, "DVI/USB Drivers"]],
  [[0x60, "mruby VM"]],
  [[0x24, "RP2350 Hardware"]],
]
bw = 360
bh = 40
gap = 4
bx = 320 - bw / 2
by = 120
```

```p5
p5.text_font(DVI::Graphics::FONT_OUTFIT_BOLD_18)
p5.text_align(:center)

rows.each_with_index do |row, i|
  col_gap = 4
  col_w = (bw - col_gap * (row.size - 1)) / row.size
  row.each_with_index do |col, j|
    x = bx + j * (col_w + col_gap)
    y = by + i * (bh + gap)
    p5.fill(col[0])
    p5.no_stroke
    p5.rect(x, y, col_w, bh)
    p5.text_color(0xFF)
    p5.text(col[1], x + col_w / 2, y + 12)
  end
end
```

# Goals

1. Run rich embedded applications with mruby
2. Build my own computer with my own hands
3. **A good first choice for learning programming**

{::wait/}

- No complex OS, just connect a display and a keyboard
- Fully hackable and open source

GitHub:
- harukasan/harucom-os
- harukasan/harucom-board

# Dive deep into the architecture

# Problem 1: 640x480 @ 60Hz DVI output

How hard can it be?

# Pixel clock frequency

- DVI requires a continuous pixel stream
- 800 x 525 x 60 Hz = **25.2 MHz**

```p5
# DVI frame timing diagram
s = 0.4
ox = 320 - (800 * s).to_i / 2
oy = 180

g = DVI::Graphics
font = g::FONT_SOURCE_CODE_PRO_18
font_bold = g::FONT_SOURCE_CODE_PRO_BOLD_18

# Total frame area (800 x 525)
tw = (800 * s).to_i
th = (525 * s).to_i
p5.fill(0x24)
p5.no_stroke
p5.rect(ox, oy, tw, th)

# Active area (640 x 480)
aw = (640 * s).to_i
ah = (480 * s).to_i
bpx = (48 * s).to_i
bpy = (33 * s).to_i
ax = ox + bpx
ay = oy + bpy
p5.fill(0xFF)
p5.rect(ax, ay, aw, ah)
p5.fill(0x64)
p5.rect(ax, ay, aw, 10*s)

# Active area label
p5.text_font(font)
p5.text_color(0x64)
p5.text_align(:left)
p5.text_font(font_bold)
p5.text("Active area", ax + 10, ay + 10)
p5.stroke(0x64)
p5.line(ax + 10, ay + 30, ax + aw - 10, ay + 30)
p5.text_align(:center)
p5.text_font(font)
p5.text("640 x 480", ax + aw / 2, ay + ah / 2 - 4)

# Horizontal dimensions (below the diagram)
hy = oy + th + 10

# Total width line and label
p5.stroke(0x49)
p5.stroke_weight(2)
p5.line(ox, hy, ox + tw, hy)
p5.line(ox, hy, ox + 5, hy - 5)
p5.line(ox, hy, ox + 5, hy + 5)
p5.line(ox + tw, hy, ox + tw - 5, hy - 5)
p5.line(ox + tw, hy, ox + tw - 5, hy + 5)
p5.stroke_weight(1)
p5.text_color(0x40)
p5.text_font(font_bold)
p5.text("H total: 640+16+96+48 = 800 px", ox + tw / 2, hy + 4)

# Vertical dimensions (right of the diagram)
vx = ox + tw + 10
p5.stroke(0x49)
p5.stroke_weight(2)
p5.line(vx, oy, vx, oy + th)
p5.line(vx, oy, vx - 5, oy + 5)
p5.line(vx, oy, vx + 5, oy + 5)
p5.line(vx, oy + th, vx - 5, oy + th - 5)
p5.line(vx, oy + th, vx + 5, oy + th - 5)
p5.stroke_weight(1)

p5.text_align(:center)
p5.text_color(0x40)
p5.push_matrix
p5.translate(vx, oy + th / 2 - 4)
p5.rotate(-Math::PI / 2)
p5.text("V total: 480+10+2+33", 0, 10)
p5.text("= 525 lines", 0, 30)

p5.pop_matrix
```

# DVI bit rate

DVI uses TMDS: 8b/10b encoding per channel
- 3 data channels (R, G, B) + 1 clock channel
- Each channel: 25 MHz x 10 bits = **250 Mbps**

# HSTX: High-Speed Serial Transmit

- Dedicated high-speed serializer on GPIO 12-19
- 4 differential pairs for TMDS output
- Hardware TMDS encoding (8b/10b)
- DMA-fed: minimal CPU intervention

# How HSTX works

- Command expander: interprets command from the FIFO
  - Each command specifies how to expand following data
  - Sync periods: repeat raw sync symbols
  - Active region: TMDS-encode pixel data
- IRQ handler builds commands + pixels per scanline

```p5_setup
# Block diagram layout
boxes = [
  "DMA",
  "HSTX FIFO",
  "Command\nExpander",
  "Shift\nRegister",
  "GPIO",
]

bw = 96
bh = 48
gap = 24
total_w = boxes.size * bw + (boxes.size - 1) * gap
sx = 320 - total_w / 2
sy = 280
```

```p5
p5.text_font(DVI::Graphics::FONT_OUTFIT_18)
p5.text_align(:center)
p5.text_color(0x00)

# Draw boxes and labels
i = 0
while i < boxes.size
  x = sx + i * (bw + gap)
  p5.no_fill
  p5.stroke(0x92)
  p5.stroke_weight(2)
  p5.rect(x, sy, bw, bh)
  p5.no_stroke
  lines = boxes[i].split("\n")
  if lines.size == 1
    p5.text(lines[0], x + bw / 2, sy + 16)
  else
    p5.text(lines[0], x + bw / 2, sy + 8)
    p5.text(lines[1], x + bw / 2, sy + 26)
  end
  i += 1
end

# Draw arrows between boxes
p5.stroke(0x92)
i = 0
while i < boxes.size - 1
  x1 = sx + i * (bw + gap) + bw
  x2 = sx + (i + 1) * (bw + gap)
  ay = sy + bh / 2
  p5.line(x1, ay, x2, ay)
  # Arrowhead
  p5.line(x2, ay, x2 - 4, ay - 4)
  p5.line(x2, ay, x2 - 4, ay + 4)
  i += 1
end
```

# Data rate for DMA

HSTX handles TMDS encoding, but DMA must keep up
- 1 pixel = 8 bits (RGB332)
- 25 MHz x 8 bit = **200 Mbps (25 MB/s)**
- Must feed HSTX FIFO at this rate continuously
{::wait/}
- 32 us deadline per scanline
- Any stall causes a **visible glitch on screen**

# DMA feeding strategy

- Two DMA channels: CMD + DATA
- CMD reads descriptors, programs DATA channel
- DATA writes pixels to HSTX FIFO

# Dual-core architecture

```p5
g = DVI::Graphics
p5.text_font(g::FONT_OUTFIT_BOLD_22)
p5.text_align(:center)
p5.text_color(0x00)
p5.no_fill
p5.stroke(0x00)
p5.stroke_weight(2)

# Core 0 box
p5.rect(100, 160, 200, 180)
p5.text("Core 0", 200, 170)

p5.text("Ruby VM", 200, 210)
p5.text("Console I/O", 200, 234)
p5.text("Timers", 200, 258)

# Core 1 box
p5.rect(340, 160, 200, 180)
p5.text("Core 1", 440, 170)

p5.text("DVI Output", 440, 240)
```

# Two display modes

**Graphics mode** (PicoRabbit)
- 640x480 or 320x240, switchable at runtime
- DMA reads framebuffer directly
- Core 0 handles all graphic rendering
{::wait/}
**Text mode** (IRB, editor)
- VRAM: 106 x 37 character cells, no framebuffer
- Core 1 renders font glyphs to pixels per scanline
- DMA sends current line while Core 1 renders next

# Cycles per scanline

At 150 MHz (default), one scanline = 32 us
- 150 MHz x 32 us = 4,800 cycles total
- DMA occupies bus during active period
- Usable: only ~1,000 cycles (H-blanking only)
{::wait/}
**Solution 1: Overclock to 250 MHz**
- Usable for rendering: ~2,200 cycles
{::wait/}
**Solution 2: Batch rendering**
- Render 4 scanlines per IRQ instead of 1

# Batch rendering

Batch rendering gives more cycle budget

- Render 4 lines at once, DMA sends while rendering next
- Core 1 can use active period too, not just blanking
- Cycle budget: **~32,000 cycles** per batch
- 8 line buffers (double-buffered x 4)
- IRQs per frame: 1,005 -> **165** (6x reduction)

# CJK wide character support

- Half-width: 256 glyphs, cached in SRAM at boot
- Full-width: 8,000+ glyphs (JIS X 0208)
  - 12px wide x 13 scanlines x 2 bytes per line
  - Too large for SRAM
{::wait/}

**Solution: per-cell glyph bitmap cache**
- Core 0 loads glyph bitmap from flash on VRAM write
- Core 1 reads cached bitmap only (zero flash access)
- Cache lives in graphics framebuffer region (~50 KB)

# Summary: Stable DVI output

Many improvements:

- **CMD-to-DATA DMA** with double-buffered descriptors
- **Batched 4 scanlines** for ~32,000 cycles render budget
- **Isolated Core 1** for DMA IRQ only
- **Built text mode renderer** with double-buffered VRAM
- **Cached CJK glyph bitmaps** to remove flash access
- Implemented cross-core VSync via ARM SEV/WFE
- Wrote scanline renderer in inline assembly
- Placed all Core 1 code in SRAM for flash safety
- Optimized scroll, SRAM bank layout, and fast path

# Problem 2: Bus contention

**mruby**: "Open the SRAM bus doors please, **Harucom**."
**Harucom**: "I'm sorry, **mruby**. I'm afraid I can't do that."

# Bus contention overview

```p5_setup
# RP2350 Bus Fabric (datasheet section 2.1)
rows = [
  [[0x80, "Core 0"], [0x80, "Core 1"], [0x80, "DMA"]],
  [[0x49, "Bus Fabric"]],
  [[0xC8, "SRAM 0-7"], [0xC4, "SCRATCH X/Y"], [0xA5, "XIP Cache"]],
]
qmi_rows = [
  [[0x49, "QMI"]],
  [[0x45, "Flash"], [0x45, "PSRAM"]],
]
bw = 480
bh = 36
row_gap = 24
col_gap = 6
bx = 320 - bw / 2
by = 90
qmi_bw = (bw - col_gap * 2) / 3
```

```p5
p5.text_font(DVI::Graphics::FONT_OUTFIT_BOLD_18)
p5.text_align(:center)

# Draw main rows
centers = []
i = 0
while i < rows.size
  row = rows[i]
  col_w = (bw - col_gap * (row.size - 1)) / row.size
  ry = by + i * (bh + row_gap)
  row_cx = []
  j = 0
  while j < row.size
    col = row[j]
    rx = bx + j * (col_w + col_gap)
    p5.fill(col[0])
    p5.no_stroke
    p5.rect(rx, ry, col_w, bh)
    p5.text_color(0xFF)
    p5.text(col[1], rx + col_w / 2, ry + 10)
    row_cx << (rx + col_w / 2)
    j += 1
  end
  centers << row_cx
  i += 1
end

# QMI subtree (under XIP Cache)
xip_cx = centers[2][2]
qmi_bx = xip_cx - qmi_bw / 2
qmi_by = by + rows.size * (bh + row_gap)

qmi_centers = []
i = 0
while i < qmi_rows.size
  row = qmi_rows[i]
  col_w = (qmi_bw - col_gap * (row.size - 1)) / row.size
  ry = qmi_by + i * (bh + row_gap)
  row_cx = []
  j = 0
  while j < row.size
    col = row[j]
    rx = qmi_bx + j * (col_w + col_gap)
    p5.fill(col[0])
    p5.no_stroke
    p5.rect(rx, ry, col_w, bh)
    p5.text_color(0xFF)
    p5.text(col[1], rx + col_w / 2, ry + 10)
    row_cx << (rx + col_w / 2)
    j += 1
  end
  qmi_centers << row_cx
  i += 1
end

# Connection lines
p5.stroke(0x80)
r0_bot = by + bh
r1_top = by + (bh + row_gap)
r1_bot = r1_top + bh
r2_top = r1_top + (bh + row_gap)
r2_bot = r2_top + bh

j = 0
while j < centers[0].size
  p5.line(centers[0][j], r0_bot, centers[0][j], r1_top)
  j += 1
end
j = 0
while j < centers[2].size
  p5.line(centers[2][j], r1_bot, centers[2][j], r2_top)
  j += 1
end
p5.line(xip_cx, r2_bot, xip_cx, qmi_by)
j = 0
while j < qmi_centers[1].size
  p5.line(qmi_centers[1][j], qmi_by + bh, qmi_centers[1][j], qmi_by + bh + row_gap)
  j += 1
end
p5.no_stroke

# Contention markers
p5.text_color(p5.color(255, 60, 60))
p5.text_font(DVI::Graphics::FONT_OUTFIT_BOLD_18)
p5.text("contention!", centers[2][0] + 20, r1_bot + 3)
p5.text("contention!", xip_cx + 20, r2_bot + 3)
```

# Key idea to resolve bus contention

mruby and DVI accessing one region causes contention

**Solution: separate memory domains**
- mruby heap on **PSRAM** (8 MB, QMI CS1)
- Core 0 (mruby): only accesses Flash + PSRAM
- Core 1 (DVI): all access confined to SRAM
  - Font data pre-cached in SRAM by Core 0
  - No flash reads during text rendering

# PSRAM and Flash share one QMI

QMI multiplexes Flash (CS0) and PSRAM (CS1)

- Flash writes block all PSRAM access
- mruby heap on PSRAM would fault if accessed

**Solution: stage via SRAM before writing to flash**
- Copy source buffer from PSRAM to SRAM
- Disable interrupts: flash-resident IRQ handlers can't run

# Bus priority

RP2350 bus fabric has configurable priority (**BUSCTRL**)
- Set DMA to highest priority
- HSTX FIFO never starves under contention
- Core 0 may stall, but display output stays smooth

# SCRATCH_X / SCRATCH_Y

Dedicated SRAM banks with independent bus ports
- SCRATCH_X (4 KB): DMA handler + scanline renderer
- SCRATCH_Y (4 KB): Font byte mask LUT

Core 0/1 stacks moved to main SRAM to make room

# Summary: Resolving bus contention

**A Few Hardfaults Later...**

mruby VM runs stably on Harucom!

- **PSRAM** provides a generous heap for the mruby VM
- **Separating mruby and DVI** eliminates bus contention

# Boot sequence

LDO? "Go," PLL? "Go," DMA? "Go," HSTX? "Go."
Flight: "Harucom?" --- Harucom: "We're go, Flight."
Flight: "Launch control, this is Houston. We are go for launch."

# Boot sequence overview

```
Power on
  -> Initialize PSRAM
  -> Install system files to flash
  -> Start DVI output on Core 1
  -> Initialize USB host
  -> Start mruby VM on Core 0
```

{::wait/}
Bootstrap code embedded in main.c:
```ruby
lfs = Littlefs.new(:flash, label: "HARUCOM")
VFS.mount(lfs, "/")
$LOAD_PATH = ["/lib"]
load "/system.rb"
```

# system.rb

Runs USB and keyboard polling as background tasks

```ruby
$console = Console.new
$keyboard = Keyboard.new

Task.new(name: "usb_host") do
  loop { USB::Host.task; Task.pass }
end
Task.new(name: "keyboard") do
  loop { $keyboard.poll; Task.pass }
end
line_editor = LineEditor.new(console: $console, ...)
IRB.new(console: $console, ...).start
```

# Cooperative multitasking

- mruby-tasks: cooperative scheduling on single core
- 1 ms timer interrupt triggers scheduler
- Task.pass yields CPU explicitly

```
Task.new(name: "keyboard") do
  loop do
    $keyboard.poll
    Task.pass
  end
end
```

# Keyboard input

**picoruby-usb-host**: raw HID state via PIO-USB
- USB::Host.task: drives TinyUSB from background task
- USB::Host.keyboard_keycodes / .keyboard_modifier

**picoruby-keyboard-input**: keycodes -> Ruby key events
- Keyboard::Key: holds key state (name, char, modifiers)
- Keyboard.key(...): returns cached Key for fast matching
- Software key repeat (400 ms initial, 50 ms interval)
- Ctrl-C flag for synchronous interrupt

# IRB on Harucom

- Multiline input via Reline-like LineEditor
- Sandbox isolates user code; Ctrl-C safely interrupts

```ruby
loop do
  script = @editor.readmultiline(PROMPT, PROMPT_CONT) do |input|
    @sandbox.compile("begin; _ = (#{input}\n); rescue => _; end; _")
  end
  break unless script # Ctrl-D
  ...
  @sandbox.execute
  wait_sandbox
  @sandbox.suspend
  ...
  puts "=> #{@sandbox.result.inspect}"
end
```

# Drawing API

**DVI::Graphics**: low-level drawing primitives
- set_pixel / get_pixel, fill, commit
- set_blend_mode, set_alpha

**P5**: wraps DVI::Graphics with Processing / p5.rb API
- Shapes: rect, circle, line, triangle, arc, bezier, text
- Transforms: translate, rotate, scale, push/pop_matrix
- State: fill, stroke, stroke_weight, blend_mode

# P5: Processing-like API

```ruby
p5.background(0x24)
p5.stroke(0xE0)
p5.no_fill
p5.push_matrix
p5.translate(320, 200)
t = DVI.frame_count * 0.02
i = 0
while i < 20
  p5.rotate(0.2 + Math.sin(t) * 0.1)
  p5.scale(0.9, 0.9)
  p5.rect(-80, -80, 160, 160)
  i += 1
end
p5.pop_matrix
```

# demo

```p5
p5.background(0x24)
p5.stroke(0xE0)
p5.no_fill
p5.push_matrix
p5.translate(320, 200)
t = DVI.frame_count * 0.02
i = 0
while i < 20
  p5.rotate(0.2 + Math.sin(t) * 0.1)
  p5.scale(0.9, 0.9)
  p5.rect(-80, -80, 160, 160)
  i += 1
end
p5.pop_matrix
```

# Everything is Ruby

- Console and LineEditor with Ruby syntax highlight
- Japanese input (SKK, T-Code)
- IRB
- Text editor
- Graphics library
- And this presentation

# Future plans

- Reduce hardware cost for mass production
- MIPI DSI support for mobile display panels
- HD (720p) output
- Keep PicoRuby in sync with upstream
- Contribute back to mruby

**Open source hardware and software**
GitHub:
- harukasan/harucom-os
- harukasan/harucom-board

# Thank you!

More details:
- https://harucom.org/

GitHub:
- harukasan/harucom-os
- harukasan/harucom-board

Social networks:
- X (formerly Twitter): @harukasan
- Discord: @harukasan
- Blog: https://harukasan.dev/
