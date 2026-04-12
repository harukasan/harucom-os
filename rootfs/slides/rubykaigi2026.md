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
a.k.a Harukasan

* Software Engineer
* Electronics Hobbyist
* Also the CTO of Pixiv Inc.

# Harucom Board

- RP2350A (ARM Cortex-M33, dual core)
- 520 KB SRAM
- 16 MB Flash
- 8 MB PSRAM
- DVI output (640x480 @ 60Hz)
- USB keyboard input
- Audio output
- Grove connector

# Now available on BOOTH!

BOOTH: a marketplace for creative endeavors
powered by Ruby on Rails

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

```p5
g = DVI::Graphics
p5.text_font(g::FONT_SOURCE_CODE_PRO_18)
p5.text_align(:center)

# Stack diagram
layers = [
  [0xE0, "Application (Ruby)"],
  [0xA0, "Harucom OS (Ruby)"],
  [0x80, "PicoRuby"],
  [0x60, "mruby VM"],
  [0x24, "RP2350 Hardware"],
]
bw = 360
bh = 40
bx = 320 - bw / 2
by = 120
layers.each_with_index do |layer, i|
  p5.fill(layer[0])
  p5.no_stroke
  p5.rect(bx, by + i * (bh + 4), bw, bh)
  p5.text_color(0xFF)
  p5.text(layer[1], 320, by + i * (bh + 4) + 12)
end
```

{::wait/}

- Display output + USB keyboard input
- FAT filesystem on flash
- Cooperative multitasking

# Goals

1. Run rich embedded applications with mruby
2. Build my own computer with my own hands

{::wait/}

3. **The best first computer for learning programming**

{::wait/}

- No complex OS, just a TV and a keyboard
- Grove connector for hardware hacking
- Fully hackable and open source

# Dive deep into the architecture

# Problem 1: 640x480 @ 60Hz DVI output

How hard can it be?

# Pixel clock frequency

DVI requires a continuous pixel stream

- H total: 640 + 16 + 96 + 48 = 800 pixels
- V total: 480 + 10 + 2 + 33 = 525 lines

- 800 x 525 x 60 Hz = **25.2 MHz**
- Must output one pixel every 40 ns

```p5
# DVI frame timing diagram
s = 0.4
ox = 300
oy = 190

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
p5.fill(p5.color(0, 80, 200))
p5.rect(ox + bpx, oy + bpy, aw, ah)

g = DVI::Graphics
p5.text_font(g::FONT_SOURCE_CODE_PRO_18)
p5.text_color(0xFF)
p5.text_align(:center)
p5.text("640 x 480", ox + bpx + aw / 2, oy + bpy + ah / 2 - 4)

hy = oy + th + 12
p5.stroke(0x49)
p5.line(ox + bpx, hy, ox + bpx + aw, hy)
p5.no_stroke
p5.text_color(0xDB)
p5.text("640", ox + bpx + aw / 2, hy + 4)

hy2 = hy + 16
p5.stroke(0x49)
p5.line(ox, hy2, ox + tw, hy2)
p5.no_stroke
p5.text_color(0x92)
p5.text("800", ox + tw / 2, hy2 + 4)

vx = ox + tw + 8
p5.text_align(:left)
p5.text_color(0xDB)
p5.text("480", vx, oy + bpy + ah / 2 - 4)
p5.text_color(0x92)
p5.text("525", vx, oy + th / 2 - 4)
```

# DVI bit rate

DVI uses TMDS: 10-bit encoding per channel

- 3 data channels (R, G, B) + 1 clock channel
- Each channel: 25 MHz x 10 bit = **250 Mbps**

- Total wire rate: **1 Gbps** across 4 differential pairs
- One bit every **4 ns**

# HSTX: High-Speed Serial Transmit

RP2350 has a built-in solution: **HSTX**

- Dedicated high-speed serializer on GPIO 12-19
- 4 differential pairs for TMDS output
- Hardware TMDS encoding (8b/10b)
- DMA-fed: zero CPU intervention

# How HSTX works

```
DMA -> HSTX FIFO -> Shift Register -> TMDS -> GPIO
```

- clk_hstx = 125 MHz (sys_clk / 2)
- CLKDIV = 5, N_SHIFTS = 5, SHIFT = 2 bits
- 125 / 5 = 25 MHz pixel clock

{::wait/}

- HSTX command expander controls output mode
  - Sync periods: repeat sync symbols
  - Active region: TMDS-encode pixel data
- DMA feeds commands + pixels, HSTX does the rest

# Data rate for DMA

HSTX handles TMDS encoding, but DMA must keep up

- 1 pixel = 8 bits (RGB332)
- 25 MHz x 8 bit = **200 Mbps (25 MB/s)**

{::wait/}

- 1 scanline = 800 pixels in 32 us
- Must fill HSTX FIFO continuously
- Any stall = **visible glitch on screen**

# Dual-core architecture

```p5
g = DVI::Graphics
p5.text_font(g::FONT_OUTFIT_BOLD_18)
p5.text_align(:center)
p5.text_color(0x00)
p5.no_fill
p5.stroke(0x00)
p5.stroke_weight(2)

# Core 0 box
p5.rect(100, 160, 200, 180)
p5.text("Core 0", 200, 170)

p5.text("Ruby VM", 200, 210)
p5.text("STDIO", 200, 234)
p5.text("Timers", 200, 258)
p5.text("File I/O", 200, 282)

# Core 1 box
p5.rect(340, 160, 200, 180)
p5.text("Core 1", 440, 170)

p5.text("DVI Output", 440, 210)
p5.text("DMA IRQ", 440, 234)
p5.text("Scanline Render", 440, 258)
```

# Two display modes

**Text mode** (IRB, editor)
- 106 x 37 character cells
- Scanline rendering from VRAM

{::wait/}

**Graphics mode** (PicoRabbit, P5)
- 640x480 framebuffer
- Direct DMA from SRAM

# Graphics mode

- 640x480 framebuffer in SRAM (300 KB)
- DMA reads framebuffer directly
- Core 1 only builds DMA commands

{::wait/}

- Simple, but memory-hungry
- All rendering done on Core 0

# Text mode: scanline rendering

- No framebuffer, only VRAM (106 x 37 cells, ~15 KB)
- Render pixels from VRAM + font data per scanline

{::wait/}

- While DMA sends current line,
  Core 1 renders the next line
- Must keep up with 25 MHz pixel clock

# Graphics mode vs Text mode

```p5
g = DVI::Graphics
p5.text_font(g::FONT_SOURCE_CODE_PRO_14)
p5.text_color(0xFF)

# Table header
headers = ["", "Graphics", "Text"]
cols = [120, 300, 460]
y = 140
headers.each_with_index do |h, i|
  p5.text_align(:center)
  p5.text(h, cols[i], y)
end

# Separator
p5.stroke(0x49)
p5.line(60, y + 14, 580, y + 14)
p5.no_stroke

# Rows
rows = [
  ["Resolution", "640x480", "640x480"],
  ["Memory", "300 KB + PSRAM", "~15 KB VRAM"],
  ["Core 1 load", "Idle", "Scanline render"],
  ["Core 0 load", "All rendering", "Light"],
]
rows.each_with_index do |row, ri|
  ry = y + 34 + ri * 28
  p5.text_align(:left)
  p5.text_color(0xDB)
  p5.text(row[0], 70, ry)
  p5.text_align(:center)
  p5.text_color(0xFF)
  p5.text(row[1], cols[1], ry)
  p5.text(row[2], cols[2], ry)
end
```

# Cycles per scanline

At 150 MHz (default), one scanline = 32 us

- 150 MHz x 32 us = 4,800 cycles total
- Usable: only ~1,000 cycles (H-blanking only)

{::wait/}

**Overclocked to 250 MHz**

- 250 MHz x 32 us = 8,000 cycles total
- Usable for rendering: ~2,240 cycles

# Batch rendering

Render 4 scanlines per DMA IRQ

- Budget: 2,240 x 4 = **32,000 cycles** per batch
- Actual rendering: ~8,000 cycles (4 lines)
- Headroom: ~24,000 cycles

{::wait/}

- 8 line buffers (double-buffered x 4)
- DMA reads 4 lines while CPU renders next 4

# CJK wide character support

- Half-width: 256 glyphs, cached in SRAM at boot
- Full-width: 8,000+ glyphs (JIS X 0208)
  - 12px wide x 13 scanlines x 2 bytes each
  - Too large for SRAM

{::wait/}

- Per-cell glyph bitmap cache (~50 KB)
- Core 0 loads glyph from flash on write to VRAM
- Core 1 reads bitmap only (zero flash access)
- Shares memory with graphics framebuffer

# Problem 2: Bus contention

> C code: stable DVI output. Done!
> Add mruby VM... screen freezes.

{::wait/}

**Bus contention between cores**

# Bus contention patterns

```p5
g = DVI::Graphics
p5.text_font(g::FONT_SOURCE_CODE_PRO_18)
p5.text_color(0xFF)
p5.text_align(:center)

# SRAM banks
p5.fill(p5.color(0, 80, 200))
p5.no_stroke
p5.rect(220, 120, 200, 40)
p5.text("SRAM (10 banks)", 320, 134)

# QMI bus
p5.fill(p5.color(200, 120, 0))
p5.rect(220, 220, 200, 40)
p5.text("QMI Bus", 320, 234)

# Flash
p5.fill(0x49)
p5.rect(140, 300, 120, 36)
p5.text("Flash (XIP)", 200, 312)

# PSRAM
p5.fill(0x49)
p5.rect(380, 300, 120, 36)
p5.text("PSRAM", 440, 312)

# Core 0
p5.fill(p5.color(0, 160, 0))
p5.rect(80, 40, 100, 36)
p5.text("Core 0", 130, 52)

# Core 1
p5.fill(p5.color(200, 40, 0))
p5.rect(270, 40, 100, 36)
p5.text("Core 1", 320, 52)

# DMA
p5.fill(p5.color(160, 0, 160))
p5.rect(460, 40, 100, 36)
p5.text("DMA", 510, 52)

# Connections
p5.stroke(0x92)
p5.line(130, 76, 260, 120)
p5.line(320, 76, 320, 120)
p5.line(510, 76, 420, 120)
p5.line(130, 76, 260, 220)
p5.line(320, 76, 320, 220)
p5.line(200, 260, 200, 300)
p5.line(440, 260, 440, 300)
p5.no_stroke

# Contention markers
p5.text_color(p5.color(255, 60, 60))
p5.text_font(g::FONT_SOURCE_CODE_PRO_18)
p5.text("!!", 240, 90)
p5.text("!!", 280, 190)
```

# Solution: Separate memory domains

- Core 0 (mruby): Flash + **PSRAM** only
- Core 1 (DVI): **SRAM** only

{::wait/}

- mruby heap entirely on PSRAM (8 MB)
- Font data pre-cached in SRAM by Core 0
- Core 1 code in SCRATCH_X (no flash fetch)
  -> Eliminates QMI bus contention

{::wait/}

**No shared bus, no contention**

# Bus priority

- DMA gets highest bus priority
- SRAM bank contention: DMA always wins
- HSTX FIFO never starves

{::wait/}

- Core 0 may stall, but Ruby doesn't need real-time
- Display output is always smooth

# SCRATCH_X / SCRATCH_Y

Dedicated SRAM banks with independent bus ports

- SCRATCH_X (4 KB): DMA IRQ handler + scanline renderer
- SCRATCH_Y (4 KB): Font byte mask LUT

{::wait/}

- No contention with main SRAM
- Core 0/1 stacks moved to main SRAM
- IRQ handler fetch never conflicts with other access

# Line buffer bank striping

- RP2350 SRAM: 8 banks, word-interleaved
- Line buffer stride: 644 bytes = 161 words
- 161 and 8 are coprime

{::wait/}

- 8 buffers land on 8 different banks
- DMA and CPU access same pixel offset
  but different buffers = different banks
- **Zero contention between read and write**

# Boot sequence

```
Power on
  -> Mount FAT filesystem
  -> Initialize PSRAM (mruby heap)
  -> Start Core 1 (DVI output)
  -> Start mruby VM (Core 0)
  -> Load /system.rb
```

{::wait/}

```ruby
fat = FAT.new(:flash, label: "HARUCOM")
VFS.mount(fat, "/")
$LOAD_PATH = ["/lib"]
load "/system.rb"
```

# system.rb

Entry point of Harucom OS

```ruby
# USB host background task
Task.new(name: "usb_host") do
  loop { USB::Host.task; Task.pass }
end

# Set up console and keyboard
$console = Console.new
$keyboard = Keyboard.new
line_editor = LineEditor.new(
  console: $console, keyboard: $keyboard)

# Keyboard polling background task
Task.new(name: "keyboard") do
  loop { $keyboard.poll; Task.pass }
end

IRB.new(console: $console,
  keyboard: $keyboard,
  line_editor: line_editor).start
```

# Cooperative multitasking

- mruby-tasks: cooperative scheduling on single core
- 1 ms timer interrupt triggers scheduler
- Task.pass yields CPU explicitly

{::wait/}

- USB polling: background
- Keyboard input: background
- Main script: foreground

# Keyboard input

```
USB Keyboard
  -> PIO-USB (GPIO 8/9)
  -> TinyUSB HID callback
  -> Keyboard#poll (Ruby)
  -> KeyboardInput ($stdin)
```

{::wait/}

- HID report: 6 keycodes + modifier byte
- Keyboard::Key: keycode -> char/name conversion
- Software key repeat (400ms initial, 50ms interval)
- Ctrl-C flag for interrupt support

# IRB on Harucom

```ruby
irb> 1 + 1
=> 2
irb> "Hello, RubyKaigi!"
=> "Hello, RubyKaigi!"
```

{::wait/}

- Multi-line editing with LineEditor
- Console with ANSI escape sequence support
- Sandbox isolation for eval (PicoRuby)
- Ctrl-C interrupt support

# Sandbox and Ctrl-C

```ruby
def wait_sandbox(sandbox)
  while sandbox.state != :DORMANT
    c = @keyboard.read_char
    if c == Keyboard::CTRL_C
      sandbox.stop
      return
    end
    sleep_ms 5
  end
end
```

{::wait/}

- Sandbox: isolated mruby VM (PicoRuby)
- IRB reads key queue while sandbox runs
- Ctrl-C -> sandbox.stop to halt execution

# Reline-like multiline editor

- Cursor movement, line insert/delete
- Scrollback buffer
- UTF-8 wide character width handling

{::wait/}

- Built on `DVI::Text` VRAM API
- ANSI escape sequence color support
- **Pure Ruby implementation**

# P5: Processing-like API

```ruby
p5 = P5.new
p5.background(0x00)
p5.fill(0xE0)
p5.circle(320, 240, 100)
p5.commit
```

{::wait/}

- rect, circle, line, text
- Affine transforms, blend modes
- 640x480 double-buffered rendering

# Everything is Ruby

- Keyboard input: Ruby
- Console: Ruby
- IRB: Ruby
- Editor: Ruby
- This presentation: Ruby

{::wait/}

**mruby is powerful enough to build
a complete computing experience**

# What's next

- Reduce hardware cost
- MIPI DSI display support
- More educational tools
- Better editor (syntax highlighting)
- Networking capabilities

{::wait/}

**Open source hardware and software**
GitHub: harukasan/harucom-os

# Thank you!

- GitHub: harukasan/harucom-os
- @harukasan

{::wait/}

**Questions?**
