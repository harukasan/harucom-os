---
title: What Happened<br>After 1.0.0
subtitle: RubyKaigi 2026 Follow-up
author: Shunsuke Michii
theme: rubykaigi2026
allotted_time: 10
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
- 16 MB Flash, 8 MB PSRAM
- DVI output (640x480 @ 60Hz), USB keyboard, audio
- **Harucom OS**: mruby, PicoRuby, the rest in Ruby

Tagged **1.0.0** two days before RubyKaigi 2026.
Since then: 233 commits, 36 pull requests, 172 files.

# Harucom on WASM

The same OS, in a browser tab.

# Harucom OS in a tab

- The same C sources and the same `rootfs/` userland
- Cross-compiled with emscripten against picoruby.wasm
- DVI paints a canvas, the filesystem lives in memory
- DOM key events arrive as **USB HID reports**
- IRB, the editor, the IME and P5 boot unchanged

```
rake wasm:build && rake wasm:server
```

# One VM, two output stages

```p5_setup
shared = [
  "rootfs/ : IRB, editor, IME, P5, PicoRabbit, this deck",
  "mruby VM + PicoRuby",
  "DVI text core, graphics, synth and mixer (portable C)",
]
board = ["HSTX + DMA", "PWM + DMA", "PIO-USB"]
web = ["Canvas", "AudioWorklet", "DOM key events"]

bx = 60
bw = 520
bh = 34
gap = 4
top = 100

col_w = 250
lx = 60
rx = 330
col_top = 246
```

```p5
g = DVI::Graphics
p5.text_align(:center)
p5.no_stroke

# Shared column
i = 0
while i < shared.size
  y = top + i * (bh + gap)
  p5.fill(0x64)
  p5.rect(bx, y, bw, bh)
  p5.text_color(0xFF)
  p5.text_font(g::FONT_OUTFIT_BOLD_18)
  p5.text(shared[i], bx + bw / 2, y + 9)
  i += 1
end
shared_bottom = top + shared.size * (bh + gap) - gap

# Column headers
p5.text_color(0x00)
p5.text_font(g::FONT_OUTFIT_BOLD_22)
p5.text("RP2350", lx + col_w / 2, shared_bottom + 14)
p5.text("Browser", rx + col_w / 2, shared_bottom + 14)

# Split lines
p5.stroke(0x64)
p5.stroke_weight(2)
p5.line(lx + col_w / 2, shared_bottom, lx + col_w / 2, shared_bottom + 12)
p5.line(rx + col_w / 2, shared_bottom, rx + col_w / 2, shared_bottom + 12)
p5.no_stroke
p5.stroke_weight(1)

# Platform boxes
p5.text_font(g::FONT_OUTFIT_BOLD_18)
i = 0
while i < board.size
  y = col_top + i * (bh + gap)
  p5.fill(0xA0)
  p5.rect(lx, y, col_w, bh)
  p5.fill(0x92)
  p5.rect(rx, y, col_w, bh)
  p5.text_color(0xFF)
  p5.text(board[i], lx + col_w / 2, y + 9)
  p5.text(web[i], rx + col_w / 2, y + 9)
  i += 1
end
p5.no_fill
```

# Preemption without a timer

The board expires a timeslice from a 1 ms timer interrupt.
The browser main thread cannot be interrupted at all.

- A per-opcode hook counts opcodes and **requests** a switch
- The VM decides when to actually take it

{::wait/}
A switch yields by returning from `mrb_vm_exec`.
Returning out of a re-entrant call would corrupt the C caller,
so a pending switch waits until the stack is pure Ruby again.

# Fixes

Building on a VM is the best way to find bugs in it.

# PicoRuby #417: the rerun bug

Press Ctrl-C in IRB while a script sits inside a method call.
Everything you type after that runs the **previous** script.

# #417: a minimal repro

```ruby
sandbox.compile <<~CODE
  def m
    Task.current.suspend
  end
  m
  :old
CODE
sandbox.execute
sandbox.wait          # suspends inside m

sandbox.compile(":new")
sandbox.execute
sandbox.wait

sandbox.result        # => :old
```

# #417: the frame was not at cibase

`Sandbox#execute` installed the proc, then rewound:

```c
mrb_task_proc_set(mrb, ss->task, proc);  /* writes onto c->ci    */
mrb_task_reset_context(mrb, ss->task);   /* c->ci back to cibase */
```

- Suspended inside a method, `c->ci` is a **nested** frame
- The new proc lands there, then the rewind jumps to `cibase`
- `cibase` still holds the previous proc and its entry PC

{::wait/}
The fix is to swap the two lines.

# PicoRuby #387: rescue is not enough

```
irb> 5.times
fiber required for enumerator (NotImplementedError)
irb> 5.times
zsh: segmentation fault (core dumped)
```

IRB wraps your input in `begin ... rescue => _ ... end`.
A bare `rescue` catches `StandardError` and nothing else, so
`NotImplementedError` walked out and left `mrb->exc` set.

**One word of diff:** `rescue` becomes `rescue Exception`

# PicoRuby #420: better backtraces

- `compile(script, filename:)` sets the compiler filename
- `__FILE__` and backtraces show the real path, not `"-e"`
- `Shell#run_irb` passes `filename: "(irb)"`

So an IRB backtrace reads the way CRuby's does:

```
(irb):1:in 'Object#boom'
```

# mruby #7279: NoMemoryError

- A large enough script in the sandbox died on the board
- The PSRAM heap was barely touched
- The same sequence on a 64-bit host, under ASan:
  **heap-buffer-overflow**, 8 bytes past a 1024-byte region

{::wait/}
1024 bytes is 64 slots, `TASK_STACK_INIT_SIZE`.
The task was sized for the proc it was **created** with.

# Three layers deep

```p5_setup
steps = [
  [0x64, "Sandbox#execute swaps a compiled proc onto a task"],
  [0x64, "the task was sized for a tiny placeholder proc"],
  [0x84, "mrb_task_proc_set never grew the stack"],
  [0x84, "the frame ends up past stend"],
  [0x00, "stack_extend_alloc: stend - ci->stack wraps around"],
]
bx = 60
bw = 520
bh = 36
gap = 20
top = 104
```

```p5
g = DVI::Graphics
p5.text_align(:center)
p5.text_font(g::FONT_OUTFIT_BOLD_18)

i = 0
while i < steps.size
  y = top + i * (bh + gap)
  p5.no_stroke
  p5.fill(steps[i][0])
  p5.rect(bx, y, bw, bh)
  p5.text_color(0xFF)
  p5.text(steps[i][1], bx + bw / 2, y + 10)
  if i < steps.size - 1
    p5.stroke(0x92)
    p5.stroke_weight(2)
    ay = y + bh
    p5.line(320, ay, 320, ay + gap)
    p5.line(320, ay + gap, 316, ay + gap - 5)
    p5.line(320, ay + gap, 324, ay + gap - 5)
    p5.stroke_weight(1)
  end
  i += 1
end

# Outcome
p5.no_stroke
p5.text_color(p5.color(255, 60, 60))
p5.text_font(g::FONT_OUTFIT_BOLD_22)
p5.text("NoMemoryError, or a write past the stack", 320, top + steps.size * (bh + gap) + 2)
p5.no_fill
```

# mruby #7305: one line

```c
/* stack_extend_alloc(), ci = mrb->c->ci */

- size_t off = ci->stack ? mrb->c->stend - ci->stack : 0;
+ size_t off = ci->stack ? ci->stack - mrb->c->stbase : 0;

  if (off > size) size = off;
```

A refactor flipped "frame base offset" to "remaining room"
- Frame in range: the floor can never fire
- Frame past `stend`: unsigned wrap, negative realloc size

# Three more in mruby

- **#7308** the same `proc_set` hole for a task suspended
  mid-call-chain, plus alias procs and heap envs
- **#7309** mruby-task: the main task's name was GC'd
- **#7312** gc.c: a class method table was marked twice

All merged into mruby master, after 4.0.0

# The crackle in PWM audio

- There since the very first PWM audio implementation
- Silent on silence, worse at higher pitches
- Same noise for every waveform
- Sounded like a buffer underrun, but the buffer was fine

{::wait/}
Not a timing bug in software.
A **clock ratio** bug.

# Two clocks that never line up

The PWM compare register latches only at counter wrap.

- Carrier: 250 kHz (clk_sys 250 MHz, wrap 999)
- Samples were written at 22,050 Hz
- 250 MHz = 2^7 x 5^9, no factor 3
- So 22.05k, 24k and 48k never divide it

```p5_setup
ox = 70
cw = 24
ticks = 20
tw = cw * ticks

row_a = 312
row_b = 396
```

```p5
g = DVI::Graphics
p5.text_font(g::FONT_OUTFIT_18)
p5.text_align(:left)
red = p5.color(255, 60, 60)
green = 0x1C

# Carrier wrap grid, shared by both rows
p5.stroke(0x92)
p5.stroke_weight(1)
i = 0
while i <= ticks
  x = ox + i * cw
  p5.line(x, row_a - 14, x, row_a + 6)
  p5.line(x, row_b - 14, x, row_b + 6)
  i += 1
end

p5.stroke(0x49)
p5.stroke_weight(2)
p5.line(ox, row_a + 6, ox + tw, row_a + 6)
p5.line(ox, row_b + 6, ox + tw, row_b + 6)

# Row A: a non-integer ratio, so the write phase drifts every sample
x = ox + 6
while x < ox + tw
  latch = ox + ((x - ox) / cw + 1) * cw
  p5.stroke(red)
  p5.stroke_weight(3)
  p5.line(x, row_a, latch, row_a)
  p5.no_stroke
  p5.fill(red)
  p5.rect(x - 1, row_a - 10, 3, 16)
  p5.no_fill
  x += 82
end

# Row B: five carrier periods per sample, so the phase is pinned
x = ox + cw / 2
while x < ox + tw
  p5.stroke(green)
  p5.stroke_weight(3)
  p5.line(x, row_b, x + cw / 2, row_b)
  p5.no_stroke
  p5.fill(green)
  p5.rect(x - 1, row_b - 10, 3, 16)
  p5.no_fill
  x += cw * 5
end

p5.no_stroke
p5.stroke_weight(1)
p5.text_color(0x49)
p5.text("carrier wrap = the compare register latches", ox, 258)
p5.text_color(red)
p5.text("22,050 Hz: every write lands at a new phase", ox, row_a - 32)
p5.text_color(green)
p5.text("50,000 Hz: every write lands at the same phase", ox, row_b - 32)
```

# Fix: wrap-paced DMA

- Sample rate **50,000 Hz** = 250 MHz / 5000, exactly
- One sample spans exactly **five** carrier periods
- A pin-less PWM slice DREQs the DMA once per sample
- One endless-mode DMA channel, no re-arm seam

{::wait/}
Crackle gone. Pitch error 0 (was +0.78%).
1000 output levels (was 500).

# Sound is Ruby too

```ruby
kick = Synth.render(rate: 44100) {
  sweep(0.28, from: 160, to: 44, curve: 28, decay: 12) +
    noise(0.02, decay: 300).highpass(900) * 0.5
}
```

- Renders a WAV String the sample player takes directly
- The same file runs on the board, the test VM, and CRuby
- The whole drum kit is a Ruby file, so no audio in the repo

# This deck is the repro

PicoRabbit compiles every `p5` block into a fresh `Sandbox`,
executes it, and suspends it once per frame.

That is exactly the code path #417 and #7279 were on.

{::wait/}
An embedded target makes a very good test harness.

# Thank you!

Next: publish the browser build, MIPI DSI, 720p,
and keep sending patches upstream.

- https://harucom.org/
- harukasan/harucom-os
- harukasan/harucom-board
- X: @harukasan / Blog: https://harukasan.dev/
