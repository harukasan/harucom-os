# DMX Output

DMX512 output for stage lighting fixtures. A background engine owned by C
sends the universe (start code plus up to 512 slots) at 40 Hz over a UART
using DMA, so Ruby only updates slot values and never blocks on
transmission. The UART unit and pins are chosen at `DMX.init`, in the
same keyword style as the peripheral gems. The frame format follows
[DMX512 (ANSI E1.11)][dmx512]; the board connects to the RS-485 line
through an isolated transceiver such as the M5Stack DMX Unit on the
Grove port.

## Ruby API

Module: `DMX`

- [DMX.init](#dmxinitunit-txd_pin---integer)
- [DMX.start](#dmxstart)
- [DMX.stop](#dmxstop)
- [DMX.set](#dmxsetchannel-value)
- [DMX.set_range](#dmxset_rangechannel-values)
- [DMX.get](#dmxgetchannel---integer)
- [DMX.blackout](#dmxblackout)
- [DMX.active_slots=](#dmxactive_slots--count)
- [DMX.frame_count](#dmxframe_count---integer)
- [DMX.keepalive](#dmxkeepalive)
- [DMX.deadman_ms=](#dmxdeadman_ms--ms)

The `DMX` module exposes the C engine directly. Applications normally use
the `Board::DMX` wrapper from [rootfs/lib/board/dmx.rb](../rootfs/lib/board/dmx.rb),
which adds `[]` / `[]=` accessors and a `stop` that blacks out the rig
before halting transmission:

```ruby
require "board/dmx"

dmx = Board::DMX.new
dmx.start            # begins with all slots at zero
dmx[6] = 255         # or dmx.set(6, 255)
loop do
  dmx.keepalive      # feed the dead-man switch
  # update values...
end
dmx.stop             # blackout, wait, then stop transmission
```

Fixtures hold their last values when the DMX signal stops, so turning the
signal off does not darken the rig. Two behaviors follow from this: the
engine has a dead-man switch (see [DMX.keepalive](#dmxkeepalive)), and
`Board::DMX#stop` sends a blackout and waits 100 ms for the frames to
reach the fixtures before stopping.

### DMX.init(unit:, txd_pin:) -> Integer

Initializes a UART unit for DMX512, sets the TX pin function, claims a
free DMA channel, and creates the frame timer on its own alarm pool.
Both keywords are optional; omitted arguments select the board default
wiring from the board header
([harucom_board.h](../include/boards/harucom_board.h), the Grove port).
Pass `unit:` (e.g. `:RP2040_UART1`) and `txd_pin:` to use other wiring.
The line parameters (250000 baud, 8N2) are fixed by the standard, and
the engine only transmits, so there is no receive pin. Returns the
claimed DMA channel number, raises `ArgumentError` on an unknown unit
and `RuntimeError` when no DMA channel or alarm pool is available.
Sends nothing yet.

### DMX.start

Clears the universe to zero and starts the 40 Hz background transmission.
The clear overwrites stale fixture state, so set values after `start`,
not before.

### DMX.stop

Stops transmission. Fixtures keep their last values; use
`Board::DMX#stop` or send `DMX.blackout` first to darken the rig.

### DMX.set(channel, value)

Sets one slot. `channel` is 1-512, `value` is 0-255.

### DMX.set_range(channel, values)

Writes consecutive slots starting at `channel` from an array of values,
e.g. `DMX.set_range(1, [pan, tilt, 0, 0, 0, dimmer])`.

### DMX.get(channel) -> Integer

Reads a slot value back from the universe buffer.

### DMX.blackout

Sets every slot to zero. The rig goes dark on the next frame.

### DMX.active_slots= count

Shortens the frame to `count` slots (1-512). Shorter frames leave more
idle time between frames.

### DMX.frame_count -> Integer

Frames sent since `start`. Increases at about 40 per second; useful for
measuring the actual refresh rate.

### DMX.keepalive

Heartbeat for the dead-man switch. Call it from the application's main
loop. When the heartbeat stops for longer than `deadman_ms`, the engine
forces the whole universe to zero on every frame, so a hung or crashed VM
cannot leave the rig lit. When `keepalive` resumes, values set by Ruby
take effect again.

### DMX.deadman_ms= ms

Grace period in milliseconds before the dead-man switch trips. Default
500, `0` disables. Setting it also refreshes the heartbeat so enabling
the switch does not trip it immediately.

## C API

Defined in [dmx.h](../mrbgems/picoruby-dmx/include/dmx.h).

### dmx_universe / dmx_active_slots

```c
extern volatile uint8_t dmx_universe[1 + DMX_SLOTS];
extern volatile uint16_t dmx_active_slots;
```

The universe buffer: `[0]` is the start code (always 0x00), `[1..512]`
hold the slot values. C owns the buffer so the DMA engine can read it
without involving the VM; Ruby only updates slot values through the
accessors below.

### dmx_set / dmx_set_range / dmx_get / dmx_blackout / dmx_set_active_slots

```c
void dmx_set(uint16_t channel, uint8_t value);
void dmx_set_range(uint16_t channel, const uint8_t *values, uint16_t count);
uint8_t dmx_get(uint16_t channel);
void dmx_blackout(void);
void dmx_set_active_slots(uint16_t count);
```

Platform-independent universe access
([src/dmx.c](../mrbgems/picoruby-dmx/src/dmx.c)). Out-of-range channels
are ignored.

### dmx_init / dmx_start / dmx_stop / dmx_frame_count

```c
int dmx_init(const char *unit_name, int txd_pin);
void dmx_start(void);
void dmx_stop(void);
uint32_t dmx_frame_count(void);
```

The background transmit engine
([ports/rp2350/dmx_port.c](../mrbgems/picoruby-dmx/ports/rp2350/dmx_port.c)).
`dmx_init` returns the claimed DMA channel, or `DMX_INIT_ERR_UNIT` /
`DMX_INIT_ERR_RESOURCE` on failure.

### dmx_keepalive / dmx_set_deadman_ms

```c
void dmx_keepalive(void);
void dmx_set_deadman_ms(uint32_t ms);
```

The dead-man switch. It runs entirely in the frame timer callback, so it
works even when the mruby VM is stopped.

## Hardware Configuration

The UART unit and TX pin are `DMX.init` arguments; the defaults below
come from the board header
([harucom_board.h](../include/boards/harucom_board.h)). The Grove data
pins are the board's default I2C pins, and UART1 TX maps to the same
pin.

| Resource | Assignment |
|---|---|
| UART | UART1, 250000 baud, 8 data bits, no parity, 2 stop bits |
| TX pin | GPIO20 (`PICO_DEFAULT_I2C_SDA_PIN`, Grove port J5, to the DMX transceiver) |
| DMA | one channel, claimed dynamically at `dmx_init` (typically channel 3) |
| Timer | TIMER1 alarm 0, dedicated alarm pool for the frame state machine |

The M5 DMX Unit is a half-duplex isolated RS-485 transceiver, so its
Grove connector also carries the receive direction (GPIO21) for DMX
receive use. The transmit engine does not configure that pin.

TIMER0's four alarms are already taken (mruby task tick, PIO-USB SOF,
SDK default alarm pool), so the engine creates its alarm pool on TIMER1.

## Architecture

### Frame state machine

A repeating timer starts one frame every 25 ms (40 Hz). Each frame runs a
small alarm-driven state machine:

1. Assert BREAK (`uart_set_break`, TX low) and schedule a 176 us one-shot
   alarm.
2. Release BREAK; the line goes high for the Mark After Break. Schedule a
   12 us one-shot.
3. Kick the DMA channel with the start code plus `dmx_active_slots`
   bytes. From here the UART TX DREQ paces the transfer and the CPU is
   not involved.

BREAK is generated with `uart_set_break` rather than a baud-rate change
because the latter does not compose with DMA. The one-shot alarms use a
positive return value to reschedule from the callback's end, so interrupt
latency can only lengthen a phase, which receivers accept (the DMX512
minimums are 88 us BREAK and 8 us MAB, with no practical upper bound).

### Frame collision guard

Before starting a frame, the timer callback checks both the DMA channel
and the UART BUSY flag; DMA completion only means the bytes reached the
TX FIFO, and up to 32 bytes (about 1.4 ms) are still on the wire after
it. If the previous frame is still going out, the new frame is skipped
and the next attempt comes after 33.3 ms (30 Hz). The degrade is
self-recovering: one clean frame returns the period to 25 ms. A full
512-slot frame takes 22.8 ms, so the engine stays at 40 Hz in steady
state.

### Dead-man switch

The frame callback compares the current time against the last
`dmx_keepalive` heartbeat. Past `deadman_ms` it forces the universe to
zero on every frame until the heartbeat resumes, so an application that
sets values without calling `keepalive` stays dark, which makes the
missing heartbeat obvious. `dmx_init` and `dmx_start` also begin from a
zeroed universe to overwrite whatever state the fixtures latched from a
previous run.

### Measured timing

Oscilloscope measurements at the UART TX pin (GPIO20) with the engine
running:

| Item | Measured | Nominal / spec |
|---|---|---|
| BREAK width | 246.5 us | 176 us nominal, >= 88 us spec |
| MAB | 14.5 us | 12 us nominal, >= 8 us spec |
| Bit time | 4 us | 250000 baud |
| Frame period | 25.0 ms | 40 Hz, held at 512/160/26 active slots |

The BREAK and MAB stretch comes from higher-priority interrupts (PIO-USB
SOF, mruby task tick) delaying the phase alarms; the stretch only makes
the phases longer, which the spec allows.

## Demo

[dmx_demo.rb](../rootfs/app/dmx_demo.rb) is an IRB-launched fader
console (`run app/dmx_demo.rb`). A bank of faders drives arbitrary
channels through the engine: cursor keys select faders and change
values, `a` repatches the bank to a base address, `c` and `r` set the
channel and the value range of the selected fader, and `b` sends a
blackout. The layout is computed from the text grid dimensions at
startup, so the zoomed 320x240 console works as well. A status line
shows the frame counter and the measured refresh rate.

### Fixture files

`Ctrl-O` loads a fixture definition from `/data/dmx/fixtures/*.json`.
The files use the [Open Fixture Library][ofl] fixture format. The demo
reads a tolerant subset (`name`, `availableChannels` with
`fineChannelAliases`, `defaultValue` and capability `dmxRange`s, and
`modes`) and ignores unknown keys, so definitions downloaded from the
library work unless they rely on matrix template channels. Loading a
fixture names the faders after the selected mode's channels and shows
the capability band matching the current value, like a lighting
console. The loader is `DMX::Fixture` in
[rootfs/lib/dmx/fixture.rb](../rootfs/lib/dmx/fixture.rb), covered by
host tests ([tests/dmx_fixture_test.rb](../tests/dmx_fixture_test.rb)).
[shehds_80w_led_spot_light.json](../rootfs/data/dmx/fixtures/shehds_80w_led_spot_light.json)
covers the bench fixture in its 13 and 10 channel modes.

## References

- [DMX512 (ANSI E1.11)][dmx512]: the DMX512-A standard, published by ESTA.
- [Open Fixture Library][ofl]: the fixture definition format read by the demo.

[dmx512]: https://tsp.esta.org/tsp/documents/published_docs.php
[ofl]: https://open-fixture-library.org/
