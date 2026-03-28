---
title: Building a Standalone Ruby Programming Environment
subtitle: April 22 2026, RubyKaigi 2026
author: Shunsuke Michii
theme: dark
allotted_time: 30
---

# Self Introduction

Shunsuke Michii
a.k.a Harukasan

* Software Engineer
* Electronics Hobbyist
* Also the CTO of Pixiv Inc.

# Harucom

Now available on BOOTH!



BOOTH, a marketplace for creative endeavors
powered by Ruby on Rails, and We're hiring!


# Harucom Board

- RP2350A (ARM Cortex-M33, dual core)
- 520 KB SRAM
- 16 MB Flash
- 8 MB PSRAM
- DVI output (640x480 @ 60Hz)
- USB keyboard input
- Audio output
- Grove connector

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
# Back porch offset: H=48, V=33
bpx = (48 * s).to_i
bpy = (33 * s).to_i
p5.fill(p5.color(0, 80, 200))
p5.rect(ox + bpx, oy + bpy, aw, ah)

# Labels
g = DVI::Graphics
p5.text_font(g::FONT_SPLEEN_8X16)

# Active area label
p5.text_color(0xFF)
p5.text_align(:center)
p5.text("640 x 480", ox + bpx + aw / 2, oy + bpy + ah / 2 - 4)

# H blanking regions
hy = oy + th + 12
p5.stroke(0x49)
p5.line(ox + bpx, hy, ox + bpx + aw, hy)
p5.no_stroke
p5.text_color(0xDB)
p5.text("640", ox + bpx + aw / 2, hy + 4)

# H total dimension
hy2 = hy + 16
p5.stroke(0x49)
p5.line(ox, hy2, ox + tw, hy2)
p5.no_stroke
p5.text_color(0x92)
p5.text("800", ox + tw / 2, hy2 + 4)

# V dimension labels
vx = ox + tw + 8
p5.text_align(:left)
p5.text_color(0xDB)
p5.text("480", vx, oy + bpy + ah / 2 - 4)
p5.text_color(0x92)
p5.text("525", vx, oy + th / 2 - 4)

p5.text_align(:left)
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

- HSTX encodes raw RGB into TMDS 10-bit symbols
- DMA feeds pixel data, HSTX does the rest

# Data rate for DMA

HSTX handles TMDS encoding, but DMA must keep up

- 1 pixel = 8 bits (RGB332)
- 25 MHz x 8 bit = **200 Mbps (25 MB/s)**

{::wait/}

- 1 scanline = 800 pixels in 32 us
- Must fill HSTX FIFO continuously
- Any stall = **visible glitch on screen**

# Cycles per scanline

At 250 MHz sys_clk, one scanline = 32 us

- 250 MHz x 32 us = **8,000 cycles** total
- Usable for rendering: only **2,240 cycles**
  - 1,600 cycles (H-blanking)
  - 640 cycles (FIFO margin from 8-entry HSTX FIFO)

{::wait/}

- Text mode: 106 columns x 13px font
- Must render 640 pixels in ~2,000 cycles
- **~3 cycles per pixel**

# Making it work

Batch rendering: 4 scanlines per DMA IRQ

- Budget: 2,240 x 4 = **32,000 cycles** per batch
- Actual rendering: ~8,000 cycles (4 lines)
- Headroom: ~24,000 cycles

{::wait/}

- ARM Thumb-2 inline assembly scanline renderer
- Branchless pixel selection via LUT
- Font row cache in SRAM (zero flash access)
- Wide glyph cache pre-populated on Core 0
- LUT in SRAM9 (separate bus port, no DMA contention)

# The problem

> Modern computing is too complex for young learners

{::wait/}

- Install an OS
- Set up an editor
- Install Ruby runtime
- Learn the command line

{::wait/}

**Before writing a single line of Ruby**

# What if...

- Power on
- See a prompt
- Write Ruby

{::wait/}

**That's it.**

# Harucom Board

- RP2350 (ARM Cortex-M33, dual core)
- 520 KB SRAM + 8 MB PSRAM
- 16 MB Flash
- DVI output (640x480 @ 60Hz)
- USB keyboard input

{::wait/}

**All for $20**

# Architecture overview

- Core 0: mruby VM, IRB, file I/O
- Core 1: DVI output (real-time)

{::wait/}

- PSRAM: mruby heap (8 MB)
- Flash: FAT filesystem + firmware

# mruby on RP2350

- PicoRuby: mruby for microcontrollers
- Cross-compiled with ARM GCC
- Custom mrbgems for hardware access

{::wait/}

- `picoruby-dvi`: Graphics and text rendering
- `picoruby-usb-host`: USB keyboard
- `picoruby-keyboard-input`: Key translation

# The memory challenge

- 640x480 framebuffer = 300 KB
- RP2350 SRAM = 520 KB
- mruby VM needs memory too!

{::wait/}

- Solution: **PSRAM** (APS6404L, 8 MB)
- QMI CS1 XIP mapping
- mruby heap runs entirely on PSRAM

# DVI signal generation

- **HSTX**: RP2350 hardware serializer
- TMDS encoding in hardware
- No bit-banging, no FPGA

{::wait/}

- DMA descriptor chains
- Batch rendering (N=4 scanlines)
- Zero CPU intervention during output

# Text mode rendering

- VRAM: 106 x 37 cells
- Each cell: codepoint + color attribute
- Scanline renderer with font cache

{::wait/}

- ~2,080 cycles per scanline
- Zero FIFO underflows
- CJK wide character support

# Graphics mode

- 640x480 / 320x240 resolution
- Shapes, text, images
- Multiple blend modes

{::wait/}

- Mode switch via VSync synchronization
- Text mode and graphics mode coexist

# P5: Processing-like API

```ruby
p5 = P5.new
p5.background(0x00)
p5.fill(0xE0)
p5.circle(320, 240, 100)
p5.commit
```

{::wait/}

- Familiar API for creative coding
- Runs on the 640x480 framebuffer

# USB keyboard input

- PIO-USB: bit-banged USB host
- No external USB controller needed

{::wait/}

- HID keycode to character translation
- Background polling task
- Key repeat, modifier keys, Ctrl-C

# Console

- Built on `DVI::Text` VRAM API
- ANSI color support
- Scrollback buffer
- Cursor management

{::wait/}

- Pure Ruby implementation
- No ANSI terminal emulator needed

# IRB on Harucom

```ruby
irb> 1 + 1
=> 2
irb> "Hello, RubyKaigi!"
=> "Hello, RubyKaigi!"
```

{::wait/}

- Console + Editor::Buffer + Sandbox
- Sandbox isolation for eval
- Ctrl-C interrupt support

# Demo

**Live demo on the actual board**

# Text editor

- Full-screen editor in Ruby
- Edit, save, and run scripts
- Ctrl-S: Save, Ctrl-Q: Quit

{::wait/}

- Powered by `Editor::Buffer` from PicoRuby
- File saved to FAT filesystem on flash

# R2P2 communication

- Serial communication with external R2P2
- Raspberry Pi Pico based device
- UART connection

# Everything is Ruby

- Keyboard input: Ruby
- Console: Ruby
- IRB: Ruby
- Editor: Ruby
- This presentation: Ruby

{::wait/}

**mruby is powerful enough to build a complete computing experience**

# What's next

- More educational tools
- Better editor (syntax highlighting)
- Networking capabilities
- Open source hardware and software

# Thank you!

- GitHub: harukasan/harucom-os
- @harukasan

{::wait/}

**Questions?**
