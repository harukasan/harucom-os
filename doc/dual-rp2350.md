# Dual RP2350 Architecture Study

This document studies how to keep audio, DVI, and DMX output stable
while heavy mruby work runs, motivated by johakyu live coding sessions
that stall the whole system. It analyzes where the current single-chip
design breaks, how far the single RP2350 can be pushed without new
hardware, and what a board revision with a second RP2350 would buy.
Part 1 covers single-chip improvements, Part 2 covers dual-chip
partitionings, and the final section compares them and proposes a
phased plan.

## Current allocation and the stall budget

### Core and interrupt allocation

Everything except DVI runs on core 0 ([main.c](../src/main.c)):

| Core | Work |
|---|---|
| Core 0 | mruby VM and task scheduler, johakyu (pure Ruby), USB host, keyboard polling, PWM audio render pump (TIMER1 alarm IRQ), DMX engine (TIMER1 alarm IRQ), LittleFS flash writes, stdio |
| Core 1 | DVI scanline rendering only (DMA_IRQ_1, BASEPRI = 0x20, SRAM-resident WFI loop) |

Core 1 is deliberately empty: it renders 4 scanlines per DMA IRQ
(roughly 8,800 cycles per batch, 120 batches per frame, about 25
percent of one core at 250 MHz) and blocks every other interrupt so
that flash-resident handlers can never fault it during flash writes
(see [dvi/stability.md](dvi/stability.md)).

### How the output engines survive VM stalls today

Both output engines are already autonomous C machines, so a busy VM
does not stop them directly:

- **Audio**: the render pump (10 ms timer IRQ) mixes into a 2048-sample
  DMA ring, about 41 ms of buffered output. Ruby schedules events
  sample-accurately through a 32-slot queue
  (`PWM_AUDIO_EVENT_MAX`, [pwm_audio.c](../mrbgems/picoruby-pwm-audio/src/pwm_audio.c)).
- **DMX**: a 40 Hz timer-driven state machine transmits the universe by
  DMA, with a dead-man switch that blacks out the rig when Ruby stops
  calling `keepalive`.

What is *not* autonomous is the production of future events. The
johakyu scheduler ([scheduler.rb](../rootfs/lib/johakyu/scheduler.rb))
stages pattern queries in quarter-cycle chunks from the app main loop
(5 ms cadence) and fires each event `RESERVE_LEAD_MS` (300 ms) before
its musical target. The 300 ms lead is the whole stall budget: the
busiest preset already fires up to roughly 276 ms late on the board,
so nearly all of it is spent in normal operation. Light events are
worse off than sound: they have no C-side scheduler, so they fire from
a Ruby due list with main-loop granularity.

### Stall inventory

| Source | Mechanism | Typical duration | What breaks first |
|---|---|---|---|
| Live eval compile | `mrb_load_string` is one atomic C call; no task switch inside | tens to hundreds of ms, grows with buffer size | Scheduler tick stops; runway drains |
| Pattern staging burst | Chunk query allocates Fraction/Hap heavily | up to ~80 ms per chunk | Loop iteration stretches; lights jitter |
| GC | Collection steps on the shared heap | ms to tens of ms | Adds to every stall above |
| Flash program | IRQs disabled on core 0 per 256 B page | ~1 ms per page | Audio pump blocked; > 41 ms total starves the ring |
| Flash erase | IRQs disabled per 4 KB sector; XIP stalls chip-wide | tens to hundreds of ms per sector | Audio dropout (pump blocked and flash streams stall) |
| UI redraw and syntax analysis | Same core, same VM as the scheduler | ms per frame | Steals loop iterations from staging |

Output breaks when a single stall (or a pile-up) exceeds the staged
runway: about 300 ms plus whatever is already in the 32-slot event
queue for sound, one main-loop iteration for lights, and 41 ms of
IRQ-off time for the audio ring itself.

### Structural limits

Four properties of the current design cannot be scheduled around:

1. **One VM.** mruby is single-threaded; the scheduler, the editor,
   syntax analysis, and eval all share it. Anything atomic in the VM
   pauses event production.
2. **One flash and XIP domain.** A write disables IRQs on core 0 and
   stalls XIP for both flash and PSRAM (shared QMI), so saving a file
   fights the audio pump and flash-streamed samples.
3. **One heap and GC domain.** Editor garbage and pattern-query garbage
   are collected together.
4. **Core 1 is reserved.** Its isolation (BASEPRI, SRAM-only) is what
   makes DVI stable; loading it with general work reopens the
   contention and flash-safety problems that
   [dvi/stability.md](dvi/stability.md) exists to solve.

## Part 1: single-chip improvements

These options need no new hardware. They raise the stall budget from
hundreds of milliseconds to seconds, but none of them removes the
one-VM limit.

### 1. Deeper engine-side buffering

The cheapest and highest-value change. The audio engine already
supports sample-accurate scheduling; the queue is just small.

- Grow `PWM_AUDIO_EVENT_MAX` from 32 to 256 or more. An event is about
  24 bytes, so 256 slots cost about 6 KB of SRAM. A dense show at 10
  events per second could then hold 20 seconds or more of staged sound.
- Raise the scheduler's staging targets (`STAGE_AHEAD_MIN`, currently
  0.25 cycles) to several cycles once the queue can hold them.
  Quantized rebinding already drops staged events past the boundary,
  so live edits keep their responsiveness; the cost is only that an
  edit discards more pre-staged work.
- Add a C-side DMX event scheduler mirroring `play_at`: a timestamped
  queue of channel writes applied by the existing 40 Hz frame callback
  at each event's target frame. This gives lights the same stall
  immunity sound already has; today one long loop iteration visibly
  delays a lighting cue.

Expected outcome: sound and light both survive multi-second VM stalls,
which covers the common johakyu freezes (long evals, GC pile-ups,
staging bursts). This work is also a prerequisite for the dual-chip
design, where the link plays the role of the deep queue.

### 2. Move the audio render pump off the VM's interrupt shadow

Flash writes disable IRQs on core 0, and a single 4 KB sector erase
can exceed the 41 ms ring, so file saves can audibly drop out even
though the DMA itself keeps running from SRAM. Two placements avoid
this:

- **Drive the pump from core 1's DVI IRQ.** The DMA IRQ fires every
  scanline batch; rendering audio at VBlank (60 Hz, 16.6 ms period)
  comfortably outpaces the 41 ms ring with no new interrupt. The pump
  code and mixer state must move to SRAM-resident sections (the DVI
  handler already lives in SCRATCH_X), and the added work must fit the
  scanline latency budget; mixing 8 channels at 50 kHz costs a few
  million cycles per second, small against core 1's 75 percent idle
  time.
- **Or a dedicated core 1 timer IRQ** between the DVI priority (0x00)
  and BASEPRI (0x20), with an SRAM-resident dispatch path.

Either way, flash-streamed sources need a guard: during a flash
operation XIP stalls, so a core 1 pump touching a stream would stall
or fault where the core 0 pump today is merely paused. The engine
should render streams as silence (or from a small pre-decoded
reserve) while a flash operation is in progress, signaled by a flag
from the flash HAL.

Note: [dvi/stability.md](dvi/stability.md) describes the flash disk
driver blanking DVI around flash operations, but `dvi_set_blanking`
currently has no caller; core 1 survives flash writes through its
SRAM-resident code and caches alone. Any work in this area should
first reconcile that document with the code.

### 3. Compile cost

The atomic eval compile is the hardest single-chip problem. The
sandbox *run* is preemptible (1 ms task tick, 10 ms slices); only the
compile is not, and mruby offers no incremental compile. Mitigations:

- Keep pre-staging around evals (already implemented via
  `stage_ahead`), sized to the measured compile time of a realistic
  buffer.
- Measure and bound compile time in `johakyu_bench` so regressions
  are visible.
- Deeper buffering (item 1) absorbs the rest.

A real fix (compiling somewhere else entirely) needs a second VM, and
in practice a second chip; see Part 2.

### 4. Allocation and GC pressure

Scheduler-driven GC and the method cache are already in place. The
remaining levers are smaller:

- Pool the hot query objects (Fraction, TimeSpan, Hap) or reuse
  per-chunk arrays where the query semantics allow it.
- Keep Rational components on the small-integer path (the 1/3840
  quantization grid already helps) so staging never promotes to
  bigint.
- Tune `GC.step_limit` / `GC.debt_limit` against measured idle time in
  the 5 ms loop.

These shrink the stalls that item 1 must absorb but do not change the
structure.

### 5. Flash write hygiene during shows

- Treat file saves as a scheduled operation: pre-stage sound and light
  runway (as evals already do), then write.
- Consider an idle-time erase-ahead pass so that saves mostly pay the
  cheap program cost (about 1 ms per page) instead of sector erases.
- Do not rewrite files that are attached as `PWMAudio::Stream` (already
  a documented constraint).

### 6. Clock increase to 300 MHz

The derived clock constraints hold at 300 MHz: clk_hstx 150 MHz with
CLKDIV 6 keeps the 25 MHz pixel clock and the 2:1 sys:hstx ratio, and
300 MHz divides exactly into the 250 kHz PWM carrier (wrap 1199) with
five carrier periods per 50 kHz sample. The audio init already checks
divisibility at runtime. Costs: higher VREG voltage and thermals, and
PSRAM/QMI timing must be re-derived. Gains about 20 percent VM
throughput; worth a bench, not a plan of record.

### What the single chip cannot reach

With items 1 to 5 done, the failure mode changes from "any long stall
is audible" to "a stall longer than the staged runway is audible".
That is a large practical improvement, but:

- One VM still serializes eval, staging, and UI. During a show the
  editor still janks while chunks stage, and a pathological script can
  still outrun any finite runway.
- Flash writes still share the chip with playback; hygiene reduces but
  does not remove the coupling.
- There is no headroom for heavier workloads (more tracks, synthesis,
  higher-rate lighting) without eating the same budget.

## Part 2: dual RP2350 architectures

A second RP2350 adds a second single-threaded VM, a second flash and
XIP domain, a second 520 KB SRAM with its own bus fabric, a second 8 MB
PSRAM option, two more cores, and a second pin budget. The interesting
question is where to cut the system.

### Option A: media frontend, compute backend

One chip owns every output (DVI, audio, DMX) plus USB input; the other
runs the VM, johakyu, and the filesystem, sending draw commands and
audio events over the link.

- Outputs can never glitch from VM activity, including flash writes.
- But the scheduler still lives on the VM chip, so event production
  still stalls with the VM; the deep-queue work from Part 1 is still
  required, just relocated behind a link.
- Display traffic dominates the link: full text VRAM is about 15.7 KB
  per frame (roughly 7.5 Mbps at 60 Hz if pushed naively), graphics
  320x240 is 4.6 MB/s and 640x480 is 18.4 MB/s. A command-based
  protocol (the drawing primitives, not pixels) or a diff protocol is
  mandatory, and P5-style per-pixel workloads fit badly.
- Largest protocol surface of the three options: drawing, input,
  audio, DMX, and filesystem access all cross the link.

### Option B: UI chip and performance engine chip (recommended)

Cut along the johakyu session boundary instead of the peripheral
boundary.

| | UI chip (current board role) | Engine chip (new) |
|---|---|---|
| VM | Editor, console, IRB, syntax analysis, UniverseView | Johakyu session: clock, scheduler, dispatcher |
| Peripherals | DVI, USB host keyboard, buttons, USB device, stdio | PWM audio pins, DMX UART |
| Storage | LittleFS (scripts, data), 16 MB flash, PSRAM | Own flash for kit samples and streams, optional PSRAM |
| Cores | Core 0 VM and IO, core 1 DVI (unchanged) | Core 0 session VM and link, core 1 audio render pump |

Why this cut fits the problem:

- **Every identified stall source lives on the UI chip.** Eval
  compiles, editor redraw, syntax analysis, file saves, USB, and their
  GC all happen where no output depends on them. The engine chip's
  loop is only `session.update` plus link polling, which is exactly
  the workload the 5 ms cadence was designed for, now with a whole
  core and a private heap.
- **Compile moves off the engine entirely.** The UI chip compiles the
  buffer to mruby bytecode (`mrb_dump`) and ships it; the engine only
  loads (`mrb_load_irep`), which is fast and does not need the source.
  Closures in patterns work because they are compiled code by the time
  they cross. Both chips must run the same mruby version and VM
  configuration (MRB_INT64 etc.), which the shared build tree already
  guarantees.
- **Flash domains separate.** Saving a script on the UI chip cannot
  stall the engine's XIP; the engine's flash is written only when
  syncing kits, never mid-show.
- **The engine keeps playing if the UI dies.** The link gets dead-man
  semantics: on link silence the engine keeps the bound patterns
  running (the show goes on) while the DMX dead-man switch, now fed by
  the engine's own loop, still protects against an engine crash.
- **The engine's core 1 is free.** With no DVI there is no BASEPRI
  reservation; the audio pump moves there naturally, and headroom
  remains for future C-level synthesis.

Residual risk: the engine VM can still stall itself (a pathological
pattern's own staging cost). The Part 1 buffering work applies
unchanged and the budget is far larger because nothing else competes.

### Option C: RPC co-processor

Keep the current firmware and offload discrete jobs (pattern queries,
synthesis, syntax analysis) to the second chip over RPC. Rejected:
pattern queries are closures over VM state and cannot be serialized
piecemeal, so the only meaningful offload unit is the whole session,
which is Option B. Narrow wins (host-style synth rendering of kit
samples) do not touch the freeze problem.

### Evaluation against the stall inventory

| Stall source | Single chip (Part 1) | Option A | Option B |
|---|---|---|---|
| Eval compile | Absorbed by runway only | Absorbed by runway only | Removed from engine (compile on UI chip) |
| Staging burst | Absorbed; still shares core with UI | Same as single chip | Engine-local, whole core available |
| GC | Shared heap, tuned | VM chip heap; outputs safe | Split heaps; engine heap sees only query garbage |
| Flash write dropout | Reduced (pump move, hygiene) | Removed | Removed |
| UI jank during show | Remains | Remains (VM chip) | Removed (separate VM) |
| Lights loop-granularity | Fixed by DMX C scheduler | Fixed by protocol lead | Fixed (engine-local plus C scheduler) |

### Interconnect

Traffic under Option B is small; the link is a control plane, not a
data plane:

| Traffic | Direction | Rate | Latency need |
|---|---|---|---|
| Event and control messages (bind, tempo, DMX overrides) | UI to engine | < 1 KB/s typical | tens of ms, absorbed by lead |
| Eval bytecode | UI to engine | bursts of tens of KB | < ~1 s, user-perceived |
| Status readback (scheduler health, audio stats, DMX readback for UniverseView) | engine to UI | ~1 KB per frame polled | UI frame rate |
| Kit and sample sync | UI to engine | MB bursts, setup time only | none |
| Clock anchors | both | tens of bytes per second | jitter < ~1 ms |

Link candidates on the RP2350:

| Link | Throughput | Pins | Notes |
|---|---|---|---|
| UART (PL011) | up to clk_peri/16 = 3 Mbaud (about 300 KB/s) at the current 48 MHz clk_peri | 2 | Simplest; enough for everything above except fast sample sync |
| SPI (PL022) | master up to clk_peri/2; the slave side is limited to about clk_peri/12 (about 4 MHz) | 4 | Hard-IP slave is the bottleneck; little gain over UART |
| PIO parallel bus (8 data + clock + handshake) | tens of MB/s | ~10 | Needed only if display or bulk sample traffic crosses the link (Option A) |
| HSTX to PIO, one-way | 100+ Mbps | 2 to 8 | UI-to-engine fast lane; HSTX is TX-only and already used for DVI on the UI chip, so this suits the reverse direction or Option A's backend chip only |

Recommendation for Option B: full-duplex UART at 3 Mbaud with
length-prefixed CRC frames, plus one GPIO per direction for
attention/flow control. Kit sync at 300 KB/s moves a full drum kit
(hundreds of KB of QOA) in seconds at boot, which is acceptable; if
not, a 4-bit PIO bus is the upgrade path. The current pinout has GPIO
1, 4 to 7, 26, and 27 uncommitted, enough for the UART link, handshake
lines, and the SWD pair below; an RP2350B (48 GPIO) engine chip removes
pin pressure entirely on the new side.

### Clock synchronization

The engine chip's audio `sample_clock` is the musical timebase, as it
is today. Two independent crystals drift up to roughly 60 ppm
relative (about 3.6 ms per minute), so the UI chip cannot just count
milliseconds:

- **Anchor exchange (baseline).** The UI chip periodically measures a
  `(board_millis, engine sample_clock)` pair over the link, halving
  the round trip, exactly like the anchor pair the Ruby dispatcher
  already uses on one chip. Refreshing once per second bounds error
  well under a millisecond, far inside the 300 ms lead.
- **Hardware pulse (optional).** The engine toggles a GPIO every N
  samples (say 4096); the UI chip timestamps edges. Removes link
  jitter from the anchor at the cost of one pin.

### Engine unit on the Grove port (no board revision)

The current board routes the Grove port to GPIO 20 and 21, and those
pins are also UART1 TX and RX (which is why the DMX engine drives its
transceiver from GPIO 20 today). The port therefore already exposes a
powered, full-duplex UART at up to 3 Mbaud: a second RP2350 can attach
as a plug-in unit with no change to the main board. The unit sits
inline where the DMX transceiver sits now, carrying its own RS-485
transceiver or a pass-through Grove socket for the existing M5 DMX
Unit.

With only two signal wires available, the strongest cut is not Option
B verbatim but a variant that keeps every output on the main board and
moves only the computation out:

- **The unit runs the session VM** (clock, scheduler, dispatcher) and
  owns DMX, which must move to the unit anyway because the link now
  occupies the Grove UART.
- **Sound events travel back to the main chip's existing C audio
  engine.** The wire protocol already exists in spirit: `play_at`,
  `tone_at`, `stop_at`, and the sample bank slots are exactly the
  vocabulary the link needs. On the main chip a C-level UART handler
  (IRQ or DMA ring, no VM involvement) validates frames and injects
  them into the scheduled event queue, so a stalled UI VM cannot stop
  event delivery. Samples stay in the main chip's flash and bank
  slots, loaded at kit load as today, so no bulk sample traffic
  crosses the link.
- **The sample clock stays on the main chip.** The unit acquires
  `(unit millis, sample_clock)` anchors through a ping answered by the
  same C handler, keeping anchor jitter at microsecond scale.
- **Evals compile on the main chip** and ship as bytecode (tens of KB,
  roughly 100 ms at 3 Mbaud). The compile still pauses the UI VM, but
  every output is behind C engines by then, so the pause is cosmetic.

This variant inverts Option B's audio placement while preserving its
essential property: no VM sits between event production and the
output engines. Editor work, syntax analysis, file saves, and GC on
the main chip cannot silence the show; staging cost moves to a chip
that does nothing else. What it does not fix is the main-chip flash
write dropout (the audio ring and streams still live there), so Part 1
items 2 and 5 remain relevant, and the deep event queue of item 1 is a
hard prerequisite because the link feeds that same queue.

A second variant puts audio hardware on the unit as well, matching
Option B exactly; the main board's audio circuit then goes unused.
This is only worth the duplicated hardware if flash writes during
shows must never touch playback and the core 1 pump move is off the
table.

Practical notes:

- The Grove port supplies power; the unit regulates locally. An
  RP2350 plus transceiver is a modest load, but the connector and
  regulator current budget on the main board should be verified.
- SWD does not reach through the Grove port, so the unit updates over
  its own USB connector or a serial bootloader in the unit firmware
  spoken over the link.
- If the board breaks out any of the uncommitted GPIOs (1, 4 to 7, 26,
  27) on a header, they can add handshake lines or SWD to the same
  unit; the two-wire protocol should not depend on them.
- The unit is the Phase 3 prototype made permanent: the protocol,
  build target, and dead-man behavior all carry over unchanged to an
  eventual on-board second chip, and a Pico 2 wired to a Grove cable
  is enough to start.

### Programming and development workflow

- The engine firmware is a second build target sharing the mrbgems
  tree and build config (same VM defines), producing its own UF2.
- The UI chip programs the engine over SWD (SWCLK, SWDIO, plus reset):
  the engine UF2 is embedded in the UI chip's 16 MB flash (space is
  not a constraint) and flashed on version mismatch at boot. One USB
  cable then updates both chips, and `rake flash` stays a single step.
- Fallback: the engine's own USB or UART bootloader for bring-up.
- Prototyping needs no board revision: two Pico 2 boards, jumper wires
  for UART and the clock pulse, PWM audio and DMX rewired to the
  engine board.

### Costs and risks

- Two firmwares to version in lockstep (mitigated by the shared tree
  and a protocol version handshake).
- The link is a new failure mode; CRC framing, dead-man behavior on
  both sides, and an engine that plays on autonomously make it fail
  soft.
- Debugging spans two chips; the status readback channel should carry
  the engine's diagnostics (audio stats, scheduler health, last error)
  so the UI chip can display them.
- BOM and board area: a second RP2350, flash, crystal, and regulator
  load. PSRAM on the engine is optional; the session working set is
  far smaller than the UI chip's (no editor buffers, no fonts, no
  framebuffer), so 520 KB SRAM plus a modest heap may suffice, to be
  confirmed by measuring session heap usage.

## Recommendation and phasing

Do the single-chip buffering work first; it is cheap, it addresses the
common freezes, and the dual-chip design needs it anyway (the deep
event queue is the other end of the link protocol). Decide on the
board revision after measuring what remains.

1. **Instrument.** Add histograms for loop iteration time, compile
   time, staging chunk time, and GC pauses to `johakyu_bench` and the
   UniverseView health row, so every later phase has numbers.
2. **Single-chip stall immunity.** Grow the audio event queue, raise
   staging depth, add the C-side DMX event scheduler, and apply the
   flash write hygiene. Optionally move the audio pump to core 1.
3. **Grove-attached prototype.** A Pico 2 on the Grove port's UART1
   against an unmodified Harucom board: define the frame format and
   message set (events, bytecode, anchors, status), port the session
   loop to the engine target, and measure end-to-end timing under
   deliberate UI-side abuse (huge evals, saves, redraw storms).
4. **Productize.** Either harden the Grove engine unit as a plug-in
   product (no main board change), or fold the second RP2350 into a
   board revision (RP2350B preferred for pins, SWD programming path,
   optional clock pulse line, audio optionally moved to the engine).

## References

- [RP2350 Datasheet][rp2350-datasheet]: HSTX, PIO, PL011 UART and
  PL022 SPI clocking limits, QMI, bus fabric
- [mruby][mruby]: bytecode dump/load (`mrb_dump`, `mrb_load_irep`)
  used for shipping compiled evals between chips
- [doc/johakyu.md](johakyu.md): scheduler, staging, and lead design
- [doc/pwm-audio.md](pwm-audio.md): render pump, ring buffer, event
  queue
- [doc/dmx.md](dmx.md): frame engine and dead-man switch
- [doc/dvi/stability.md](dvi/stability.md): why core 1 is reserved

[rp2350-datasheet]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
[mruby]: https://github.com/mruby/mruby
