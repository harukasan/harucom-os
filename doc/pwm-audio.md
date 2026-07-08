# PWM Audio

3-channel waveform synthesizer played through PWM on the board's audio
pins. The output stage is a DMA stream paced by a PWM wrap DREQ at
50,000 samples per second; rendering runs autonomously in C, so Ruby
only changes tone parameters or schedules sample-accurate events.

## Ruby API

Module: `PWMAudio` (provided by the picoruby-pwm-audio mrbgem), wrapped
by [Board::PWMAudio](../rootfs/lib/board/pwm_audio.rb) which adds pin
defaults, keyword arguments, and musical note constants.

- [PWMAudio.init](#pwmaudioinitl_pin-r_pin)
- [PWMAudio.tone](#pwmaudiotonechannel-frequency-waveform-volume)
- [PWMAudio.pan](#pwmaudiopanchannel-pan)
- [PWMAudio.mute](#pwmaudiomutechannel-flag)
- [PWMAudio.stop](#pwmaudiostopchannel)
- [PWMAudio.stop_all](#pwmaudiostop_all)
- [PWMAudio.update](#pwmaudioupdate)
- [PWMAudio.sample_clock](#pwmaudiosample_clock---integer)
- [PWMAudio.tone_at](#pwmaudiotone_atsample-channel-frequency-waveform-volume---bool)
- [PWMAudio.stop_at](#pwmaudiostop_atsample-channel---bool)
- [PWMAudio.cancel_scheduled](#pwmaudiocancel_scheduledchannel)
- [PWMAudio.stats](#pwmaudiostats---array)
- [PWMAudio.deinit](#pwmaudiodeinit)

Constants: `SAMPLE_RATE` (50000), waveforms `SINE`, `SQUARE`,
`TRIANGLE`, `SAWTOOTH`.

```ruby
audio = Board::PWMAudio.new
audio.tone(0, 440, waveform: Board::PWMAudio::SINE)
audio.stop(0)

at = audio.sample_clock + Board::PWMAudio::SAMPLE_RATE   # 1 s ahead
audio.tone_at(at, 0, 880)
audio.stop_at(at + 5000, 0)                              # 100 ms note
audio.deinit
```

### PWMAudio.init(l_pin, r_pin)

Initialize PWM slices, the DMA stream, and the render pump on the given
GPIO pins. `Board::PWMAudio.new` calls this with the board's audio pins.

### PWMAudio.tone(channel, frequency, waveform, volume)

Start a tone on a channel (0-2) immediately. The change is applied to
samples rendered after the call, so it becomes audible after the
buffered samples play out (up to one buffer, about 41 ms).

### PWMAudio.pan(channel, pan)

Set stereo balance for a channel. 0 is left only, 8 is center, 15 is
right only.

### PWMAudio.mute(channel, flag)

Mute or unmute a channel without resetting its phase or parameters.

### PWMAudio.stop(channel)

Stop a channel immediately (same latency as `tone`).

### PWMAudio.stop_all

Stop all channels.

### PWMAudio.update

No-op kept for compatibility. The engine renders autonomously in C;
there is nothing to fill from Ruby.

### PWMAudio.sample_clock -> Integer

Current playback position in samples. Monotonic, advances at
`SAMPLE_RATE` per second from `init`. Use it as the time base for
`tone_at` and `stop_at`.

### PWMAudio.tone_at(sample, channel, frequency, waveform, volume) -> bool

Schedule a tone start at an absolute sample position. Returns false
when the event queue (32 entries) is full.

Events land sample-accurately only when scheduled at least the render
lead ahead of `sample_clock` (one buffer, 2048 samples, about 41 ms).
An event closer than that is applied at the current render position,
that is, as soon as possible but late.

### PWMAudio.stop_at(sample, channel) -> bool

Schedule a channel stop at an absolute sample position. Same queue and
lead requirement as `tone_at`.

### PWMAudio.cancel_scheduled(channel)

Drop all pending scheduled events for a channel. Call before
retriggering a note so a stale scheduled stop cannot cut it. Events
already rendered into the buffer cannot be cancelled.

### PWMAudio.stats -> Array

Render health counters as
`[min_lead_samples, max_pump_gap_us, drift_now, drift_min]`:

| Element           | Meaning                                                                  |
|-------------------|--------------------------------------------------------------------------|
| `min_lead_samples`| Lowest observed distance between render position and DMA reader; 0 or negative means an underrun |
| `max_pump_gap_us` | Longest interval between render pump runs                               |
| `drift_now`       | Consumed samples minus wall-clock expectation                            |
| `drift_min`       | Minimum of `drift_now`; a downward step that never recovers indicates lost output time |

### PWMAudio.deinit

Stop the pump, abort the DMA channel, and disable both PWM slices.

## C API

Defined in
[pwm_audio.h](../mrbgems/picoruby-pwm-audio/include/pwm_audio.h).
The synthesizer and event queue
([src/pwm_audio.c](../mrbgems/picoruby-pwm-audio/src/pwm_audio.c)) are
platform-independent; the output stage and render pump
([ports/rp2350/pwm_audio_port.c](../mrbgems/picoruby-pwm-audio/ports/rp2350/pwm_audio_port.c))
are RP2350-specific.

### pwm_audio_init / pwm_audio_deinit

```c
void pwm_audio_init(uint8_t l_pin, uint8_t r_pin);
void pwm_audio_deinit(void);
```

Set up (tear down) the PWM slices, DMA channel, and render pump.

### pwm_audio_set_tone / pwm_audio_set_pan / pwm_audio_set_mute / pwm_audio_stop_channel / pwm_audio_stop_all

Immediate channel control, applied to samples rendered after the call.
Updates run inside `pwm_audio_lock()`, so the renderer never sees a
half-applied change.

### pwm_audio_render_block

```c
void pwm_audio_render_block(uint64_t start_sample, uint32_t *dst, uint32_t count);
```

Render `count` samples starting at `start_sample` on the playback
timeline into `dst`, applying scheduled events at their exact sample
positions. Called from the render pump.

### pwm_audio_schedule / pwm_audio_cancel_scheduled

```c
bool pwm_audio_schedule(uint64_t when, uint8_t channel, uint32_t frequency,
                        uint8_t waveform, uint8_t volume);
void pwm_audio_cancel_scheduled(uint8_t channel);
```

Enqueue (drop) sample-accurate events. `frequency` 0 schedules a
channel stop.

### pwm_audio_sample_clock / pwm_audio_stats

```c
uint64_t pwm_audio_sample_clock(void);
void pwm_audio_stats(int32_t *min_lead, uint32_t *max_gap_us,
                     int32_t *drift_now, int32_t *drift_min);
```

Playback position and render health counters (see
[PWMAudio.stats](#pwmaudiostats---array)).

### pwm_audio_lock / pwm_audio_unlock

```c
uint32_t pwm_audio_lock(void);
void pwm_audio_unlock(uint32_t state);
```

Short critical section guarding the event queue and channel state
against the render IRQ (implemented as interrupt disable on RP2350).

## Hardware Configuration

Pins are passed to `PWMAudio.init` by
[Board::PWMAudio](../rootfs/lib/board/pwm_audio.rb).

| Item          | Value                                                        |
|---------------|--------------------------------------------------------------|
| Audio L pin   | GPIO 24 (`AUDIO_L_PIN`), PWM slice 4 channel A               |
| Audio R pin   | GPIO 25 (`AUDIO_R_PIN`), PWM slice 4 channel B               |
| Carrier       | 250 kHz (wrap 999, divider 1, clk_sys 250 MHz)               |
| Sample rate   | 50,000 Hz (exactly five carrier periods per sample)          |
| Pacer         | PWM slice 8 (wrap 4999); slices 8-11 have no GPIO on the RP2350A package |
| DMA           | one channel claimed at init, endless mode, paced by the pacer wrap DREQ |
| Render pump   | repeating timer on TIMER1 alarm 1, 10 ms interval            |
| Ring buffer   | 2048 samples (about 41 ms), 8 KB, aligned to its size        |

## Architecture

### Carrier and sample clock

The PWM CC register is double-buffered and latches only at counter
wrap, so every sample boundary is re-quantized onto the 250 kHz
carrier grid. The design keeps this re-quantization identical for
every sample: one sample spans exactly five carrier periods, and the
CC write always lands at the same phase of the carrier period. A
non-integer rate ratio (or an uncontrolled write phase) would
re-quantize each boundary differently, and the beat between the two
rates is audible as a crackle proportional to the signal slope.

clk_sys is 250 MHz, overclocked for HSTX (see [dvi.md](dvi.md)).
250 MHz = 2^7 * 5^9 has no factor 3, so the common audio rates
(48000, 44100, 24000) cannot divide it exactly; 50000 does
(250 MHz / 5000). `pwm_audio_init()` checks the divisibility at
runtime and prints a warning if the clock ever changes.

### Output stage

The pacer slice wraps once per sample and its DREQ paces a single DMA
channel in endless mode (RP2350 `TRANS_COUNT` MODE=ENDLESS): the
transfer count never decrements, so the channel streams forever with
no re-arm seam. The channel reads the ring buffer through a read ring
wrap and writes each word to the audio slice CC register unmodified;
buffer words are pre-packed in CC format (PWM channel A in the low
half-word, B in the high half-word).

Both slices count clk_sys with divider 1. Init presets their counters
and enables them with a single write to `pwm_hw->en`, so the phase
relation holds from the first cycle: the pacer wrap (and thus the CC
write) always lands in the middle of a carrier period, and the value
latches at the next carrier wrap.

On deinit, the pacer slice stops first so no DREQ pulses arrive
during the teardown, the channel enable is cleared before
`dma_channel_abort` per erratum RP2350-E5 so the abort cannot
retrigger, and the channel is released through `dma_channel_cleanup`
so the next claimer receives it in a clean state.

### Render pump

A repeating timer (TIMER1 alarm 1; TIMER0's alarms serve the task
tick, the PIO-USB SOF pool, and the SDK default pool) runs every
10 ms. It folds the DMA read pointer into a 64-bit played-sample
counter and renders forward from the last render position up to one
buffer minus a small guard ahead of the reader, in ring-contiguous
spans. The ring is prefilled with silence before the DMA starts.

Because rendering happens in the timer IRQ, a stalled Ruby VM cannot
underrun the output; the pump would have to stall for about one
buffer duration (41 ms) before the reader reaches unrendered data.
The DMA itself reads only SRAM, so playback continues through flash
operations that stall XIP.

### Synthesizer

Each channel has a 32-bit phase accumulator stepped by
`frequency << 32 / SAMPLE_RATE`. Waveforms are generated in a 12-bit
range (sine from a 256-entry table, square, triangle, and sawtooth
from the phase bits), scaled by 1.5 dB-step volume and pan tables,
mixed, soft-clipped, and scaled to the PWM level range 0-999
(1000 output levels).

### Sample-accurate scheduling

Scheduled events live in a fixed queue of 32 slots guarded by
`pwm_audio_lock()`. During block rendering, due events are applied and
the render run is shortened to the next event position inside the
block, so each event takes effect on its exact sample. Due events are
applied oldest first, with ties resolved in scheduling order, so an
overdue tone and stop for the same channel still resolve as
scheduled. Events whose position is already behind the render
position are applied at the start of the next rendered span; see
[PWMAudio.tone_at](#pwmaudiotone_atsample-channel-frequency-waveform-volume---bool)
for the resulting lead requirement.

## References

- [RP2350 Datasheet][rp2350-datasheet]: PWM (CC double buffering, wrap
  DREQ), DMA (`TRANS_COUNT` endless mode, ring wrap), erratum
  RP2350-E5
- [pico-sdk][pico-sdk]: hardware_pwm, hardware_dma, alarm pools

[rp2350-datasheet]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
[pico-sdk]: https://github.com/raspberrypi/pico-sdk
