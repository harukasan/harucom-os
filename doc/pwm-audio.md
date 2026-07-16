# PWM Audio

8-channel audio mixer played through PWM on the board's audio pins.
Each channel plays one source at a time: a waveform oscillator or a
[QOA][qoa] or 16-bit PCM WAV sample (mono or stereo), held in memory
or streamed straight from a file on the flash filesystem. The output
stage is a DMA stream paced by a PWM wrap DREQ at 50,000 samples per
second; rendering runs autonomously in C, so Ruby only changes
parameters or schedules sample-accurate events.

## Ruby API

Module: `PWMAudio` (provided by the picoruby-pwm-audio mrbgem), wrapped
by [Board::PWMAudio](../rootfs/lib/board/pwm_audio.rb) which adds pin
defaults, keyword arguments, musical note constants, and the channel
accessor.

Object layer (defined in the gem's mrblib):

- [PWMAudio::Sample](#pwmaudiosample)
- [PWMAudio::Stream](#pwmaudiostream)
- [PWMAudio::Tone](#pwmaudiotone)
- [PWMAudio::Channel](#pwmaudiochannel)

Module functions (the flat low-level API under the objects):

- [PWMAudio.init](#pwmaudioinitl_pin-r_pin)
- [PWMAudio.tone](#pwmaudiotonechannel-frequency-waveform-volume)
- [PWMAudio.pan](#pwmaudiopanchannel-pan)
- [PWMAudio.mute](#pwmaudiomutechannel-flag)
- [PWMAudio.stop](#pwmaudiostopchannel)
- [PWMAudio.stop_all](#pwmaudiostop_all)
- [PWMAudio.set_sample](#pwmaudioset_samplechannel-data)
- [PWMAudio.set_stream](#pwmaudioset_streamchannel-extents-total_length)
- [PWMAudio.load_sample](#pwmaudioload_sampleslot-data)
- [PWMAudio.play](#pwmaudioplaychannel-volume-slot)
- [PWMAudio.sample_info](#pwmaudiosample_infodata---array)
- [PWMAudio.stream_info](#pwmaudiostream_infoextents-total_length---array)
- [PWMAudio.sample_clock](#pwmaudiosample_clock---integer)
- [PWMAudio.tone_at](#pwmaudiotone_atsample-channel-frequency-waveform-volume---bool)
- [PWMAudio.play_at](#pwmaudioplay_atsample-channel-volume-slot---bool)
- [PWMAudio.stop_at](#pwmaudiostop_atsample-channel---bool)
- [PWMAudio.cancel_scheduled](#pwmaudiocancel_scheduledchannel)
- [PWMAudio.stats](#pwmaudiostats---array)
- [PWMAudio.deinit](#pwmaudiodeinit)

Constants: `SAMPLE_RATE` (50000), `CHANNELS` (8), waveforms `SINE`,
`SQUARE`, `TRIANGLE`, `SAWTOOTH`.

The [FlashFile](#flashfile) module (picoruby-flash-file mrbgem) maps
files on the flash filesystem for `PWMAudio::Stream`.

```ruby
audio = Board::PWMAudio.new

kick = PWMAudio::Sample.new(File.open("/data/kick.qoa", "r") { |f| f.read })
ch = audio.channel(3)
ch.source = kick
ch.volume = 12
ch.play                                               # one-shot
ch.play_at(audio.sample_clock + 25000)                # in 0.5 s

song = audio.channel(7)
song.source = PWMAudio::Stream.new("/data/song.qoa")  # streams from flash
song.play

lead = audio.channel(0)
lead.source = PWMAudio::Tone.new(440, waveform: PWMAudio::SINE)
lead.play                                             # continuous
lead.stop_at(audio.sample_clock + 5000)               # 100 ms note
audio.deinit
```

### PWMAudio::Sample

`Sample.new(data)` wraps a String holding a QOA or 16-bit PCM WAV
file, mono or stereo; the format is detected from the header. Raises
`ArgumentError` for anything else. Readers: `data`, `samplerate`,
`frames` (per channel), `channels`. A Sample referenced by a Channel
keeps its data alive for the engine.

WAV suits short one-shots; QOA is about one fifth the size (convert
on the host with [scripts/wav2qoa.rb](../scripts/wav2qoa.rb)):

```
ruby scripts/wav2qoa.rb kick.wav --verify
ruby scripts/wav2qoa.rb song.wav --mono --verify   # downmix stereo
```

### PWMAudio::Stream

`Stream.new(path)` plays a file on the flash filesystem by streaming:
the file's flash blocks are mapped once at creation
([FlashFile.extents](#flashfile)) and the engine decodes straight
from memory-mapped flash, so a multi-minute track plays with no RAM
buffer and no feeder task (a 5-minute mono 44.1 kHz QOA file is about
5.3 MB). Same formats as `Sample`; raises `ArgumentError` for files
small enough to be stored inline in filesystem metadata (use `Sample`
for those). Readers: `path`, `samplerate`, `frames`, `channels`,
`extents`, `bytesize`.

The extent map stays valid only while the file is untouched: writing
the file moves its blocks, so do not rewrite a file while a Stream of
it is attached. Playback also shares flash with the filesystem; a
flash erase stalls all flash reads longer than the output buffer
(about 41 ms), so heavy filesystem writes during playback cause a
dropout.

### PWMAudio::Tone

`Tone.new(frequency, waveform: SQUARE)` is a plain value object
describing an oscillator source; the engine is configured when a
channel plays it. Readers: `frequency`, `waveform`.

### PWMAudio::Channel

One mixer channel from the fixed pool, obtained with
`Board::PWMAudio#channel(index)`. Every caller shares the same
objects. The engine state is authoritative: use either the Channel
object or the module functions for a given channel index, not both.

- `source=(source)`: assign the playback source. A `Sample` or
  `Stream` is attached to the engine immediately; a `Tone` is kept
  and sent when played
- `play(volume: ..., slot: ...)` / `play_at(at, volume: ..., slot: ...)`:
  start the source. A Tone plays continuously until `stop`; a Sample
  or Stream plays one-shot from the start (a retrigger restarts it).
  `volume` defaults to the channel's `volume` attribute (0-15, default
  15). `slot` names a preloaded bank sample (`load_sample`) to play on
  this channel instead of the attached source, so several samples can
  share a channel and choke each other
- `tone(frequency, waveform:, volume:)` / `tone_at(at, ...)`:
  shorthand for assigning a Tone source and playing it
- `stop` / `stop_at(at)`: stop either source
- `pan=` (0-15), `mute=`, `volume=`, `cancel_scheduled`

### PWMAudio.init(l_pin, r_pin)

Initialize PWM slices, the DMA stream, and the render pump on the given
GPIO pins. `Board::PWMAudio.new` calls this with the board's audio pins.

### PWMAudio.tone(channel, frequency, waveform, volume)

Switch a channel's source to the oscillator and start it immediately
(a playing sample stops). Immediate verbs re-render the buffered
lead, so the change becomes audible after a few milliseconds (see
[Render pump](#render-pump)).

### PWMAudio.pan(channel, pan)

Set stereo balance for a channel. 0 is left only, 8 is center, 15 is
right only. For a stereo sample, pan attenuates one side (balance).

### PWMAudio.mute(channel, flag)

Mute or unmute a channel without resetting its phase or parameters.
The level fades over a few milliseconds (see
[Mixer](#mixer)).

### PWMAudio.stop(channel)

Stop a channel, whichever source it plays (same latency as `tone`).
The output fades over a few milliseconds and the source is released
when the fade reaches silence, so a stop never clicks.

### PWMAudio.stop_all

Stop all channels.

### PWMAudio.set_sample(channel, data)

Switch a channel's source to a QOA or 16-bit PCM WAV sample (mono or
stereo, detected by header). `data` is a String with the file bytes;
the binding keeps a reference so the data stays valid while attached.
Stops the channel but does not start playback. Raises
`ArgumentError` when the data is neither format.

### PWMAudio.set_stream(channel, extents, total_length)

Like `set_sample`, but the bytes come from a flash extent map
(`FlashFile.extents`) instead of a String in memory, so a file larger
than RAM plays by streaming. The binding keeps a reference to the
extent map. `PWMAudio::Stream` wraps this.

### PWMAudio.load_sample(slot, data)

Preload a QOA or WAV sample into a bank slot (0 up to `NUM_BANKS`),
parsing its header once. `data` is a String with the file bytes; the
binding keeps a reference so the data stays valid while loaded. A
scheduled play that names this slot (see `play`/`play_at`) copies it
onto the target channel and retriggers, so several samples can share a
channel and choke one another. Raises `ArgumentError` for an
out-of-range slot or unsupported data. Do not reload a slot while a
channel is still playing it.

### PWMAudio.play(channel, volume, slot=nil)

Play a sample from the beginning (one-shot; playback stops at the end
of the sample, and a retrigger restarts it). Without `slot`, plays the
channel's attached sample (no-op when its source is the oscillator).
With `slot`, plays that preloaded bank sample on the channel.

### PWMAudio.sample_info(data) -> Array

`[samplerate, frames, channels]` of a QOA or WAV blob (frames counts
per channel), raising `ArgumentError` when it is neither format. Used
by `Sample.new` for validation; does not touch any channel.

### PWMAudio.stream_info(extents, total_length) -> Array

`sample_info` over a flash extent map. Used by `Stream.new`.

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

### PWMAudio.play_at(sample, channel, volume, slot=nil) -> bool

Schedule a sample trigger at an absolute sample position. Same queue
and lead requirement as `tone_at`. `slot` names a preloaded bank
sample (`load_sample`) to play; without it, the channel's attached
sample triggers. The slot rides on the reservation, so two samples
scheduled on a shared channel each play their own sound.

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

### FlashFile

Module: `FlashFile` (provided by the picoruby-flash-file mrbgem).

#### FlashFile.extents(path) -> Array | nil

`[extents, bytesize]` for a file on the LittleFS partition. `extents`
is a String of packed little-endian `(u32 address, u32 length)` pairs
covering the file's data in order, each address pointing into
memory-mapped flash. LittleFS stores file data as a CTZ skip list
(data blocks prefixed by a few list pointers); this walks the list
once and records where the data bytes live, skipping the pointers.
Returns nil when the file is stored inline in directory metadata
(small files), which has no stable flash location.

The map stays valid until the file is rewritten; writing a file moves
its blocks, so consumers must not outlive the file's next write.

## C API

Defined in
[pwm_audio.h](../mrbgems/picoruby-pwm-audio/include/pwm_audio.h).
The mixer and event queue
([src/pwm_audio.c](../mrbgems/picoruby-pwm-audio/src/pwm_audio.c)) and
the QOA decoder
([src/qoa_decoder.c](../mrbgems/picoruby-pwm-audio/src/qoa_decoder.c))
are platform-independent; the output stage and render pump
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

### pwm_audio_set_sample / pwm_audio_set_stream / pwm_audio_play

```c
bool pwm_audio_set_sample(uint8_t channel, const uint8_t *data, uint32_t length);
bool pwm_audio_set_stream(uint8_t channel, const uint8_t *extent_pairs,
                          uint32_t extent_count, uint32_t total_length);
void pwm_audio_play(uint8_t channel, uint8_t slot, uint8_t volume);
```

Switch a channel's source to a QOA or WAV sample and play it
one-shot. `set_sample` takes one contiguous buffer; `set_stream`
takes packed little-endian `(u32 address, u32 length)` extent pairs
covering the file in order (see FlashFile.extents). The backing
memory must stay valid while attached (the mruby binding pins the
String). `pwm_audio_play`'s `slot` installs a preloaded bank sample
before playing, or `PWM_AUDIO_BANK_NONE` plays the attached one.

### pwm_audio_load_sample / pwm_audio_load_stream

```c
bool pwm_audio_load_sample(uint8_t slot, const uint8_t *data, uint32_t length);
bool pwm_audio_load_stream(uint8_t slot, const uint8_t *extent_pairs,
                           uint32_t extent_count, uint32_t total_length);
```

Preload a sample's properties into bank slot `slot` (0 up to
`PWM_AUDIO_NUM_BANKS`), parsing the header once. A scheduled play that
names the slot copies these properties onto its target channel and
retriggers (see `pwm_audio_play_schedule`), so several samples share a
channel and choke each other. The backing memory must stay valid while
loaded. Pass `PWM_AUDIO_BANK_NONE` to a play to keep the channel's
attached sample instead.

### pwm_audio_sample_info / pwm_audio_stream_info

```c
bool pwm_audio_sample_info(const uint8_t *data, uint32_t length,
                           uint32_t *samplerate, uint32_t *frames, uint32_t *channels);
bool pwm_audio_stream_info(const uint8_t *extent_pairs, uint32_t extent_count,
                           uint32_t total_length, uint32_t *samplerate,
                           uint32_t *frames, uint32_t *channels);
```

Validate a blob or extent map without touching any channel.

### pwm_audio_schedule / pwm_audio_play_schedule / pwm_audio_cancel_scheduled

```c
bool pwm_audio_schedule(uint64_t when, uint8_t channel, uint32_t frequency,
                        uint8_t waveform, uint8_t volume);
bool pwm_audio_play_schedule(uint64_t when, uint8_t channel, uint8_t volume, uint8_t slot);
void pwm_audio_cancel_scheduled(uint8_t channel);
```

Enqueue sample-accurate events on the shared queue: a tone start
(`frequency` 0 schedules a stop) or a sample trigger. `slot` selects a
preloaded bank sample for the trigger, or `PWM_AUDIO_BANK_NONE` keeps
the channel's attached sample. `cancel_scheduled` drops all pending
events for the channel.

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

The rendered lead would delay immediate changes by up to a full
buffer, so the immediate channel verbs (tone, play, stop, pan, mute,
and source attachment) rewind the rendered-ahead region to just in
front of the reader and re-render it with the new state. The change
becomes audible after a small guard (about 4 ms) while the underrun
protection stays at the full buffer. Every active source steps back
along the timeline with the rewind, before the state change applies:
oscillator phases rewind exactly, and sample positions re-seek (QOA
by frame, since each frame carries its own predictor snapshot), so
the re-rendered span continues seamlessly from the rewind point
instead of jumping to where the discarded rendering had advanced.
The refill runs in short bites with interrupts enabled between them,
so IRQ latency stays bounded. One caveat: scheduled events already
applied inside the rewound span shift to its start, so immediate
verbs should not race in-flight scheduled events; the scheduled path
(tone_at, play_at, stop_at) is unaffected and stays sample accurate.

### Mixer

Each of the `CHANNELS` channels plays one source, selected by
`set_tone` / `set_sample` / `set_stream`, into a shared volume
(1.5 dB steps), pan, and mute stage. Channels mix as signed signals
around a constant mid-scale bias (the output idles at 50 percent PWM
duty), so playing or stopping a channel never moves the DC level; a
moving DC level would thump through the AC coupling. The mix is
soft-clipped around the bias and scaled to the PWM level range 0-999
(1000 output levels). A mono source contributes the same signal to
both sides; a stereo sample keeps its sides separate, with pan acting
as balance. The bias itself ramps up at init and down at deinit
(about 10 ms), the only times the DC level moves.

A source's instantaneous value is generally nonzero when it is cut,
so an instant level change still clicks. The mixer therefore slews
each channel's gain toward its target by a fixed step per sample
(full scale in about 3.6 ms): starts fade in (an idle channel's gain
rests at zero), stops and mute changes fade out, and a stopped source
is released only when its fade reaches silence. A sample that runs
out of data holds its last value while the fade drains it, so a
one-shot that does not end at zero still stops cleanly. Two paths
remain outside this guarantee: retriggering a playing sample and
switching a playing channel's source replace the signal at the
current gain, so they can step by the difference between the old and
new source values.

The oscillator source is a 32-bit phase accumulator stepped by
`frequency << 32 / SAMPLE_RATE`, generating a 12-bit sine (256-entry
table), square, triangle, or sawtooth from the phase bits. The square
and sawtooth are band-limited with a 2-point PolyBLEP residual at each
edge, which places the step at its true fractional position instead of
on the sample grid and suppresses the audible-band aliasing of the
naive waveforms by roughly 20 dB. Sine is already band-limited and
triangle's aliasing is mild, so both are generated directly.

### Sample playback

The sample source streams one QOA or 16-bit PCM WAV file, mono or
stereo. Bytes come through a byte source
([src/byte_source.h](../mrbgems/picoruby-pwm-audio/src/byte_source.h)):
one contiguous buffer for in-memory samples, or a list of flash
extents for files streamed from the filesystem. Both formats and
both source kinds share the same decode and mixing path.

QOA stores 16-bit audio at about 3.2 bits per sample in 64-bit
slices of 20 quantized residuals per channel, decoded by an integer
LMS predictor
([src/qoa_decoder.c](../mrbgems/picoruby-pwm-audio/src/qoa_decoder.c);
the predictor math and tables follow the MIT reference
implementation, while the slice-granular streaming structure is
specific to this engine). Slice groups (one slice per channel) are
decoded on demand while mixing, so only the file bytes are held and
the sustained read rate is a few kilobytes per second per channel.
Decoding costs a few tens of integer operations per sample inside
the render pump. WAV data needs no decoding and is read frame by
frame.

A 16.16 fixed-point phase accumulator resamples the source rate to
the output rate with linear interpolation, so any source sample rate
works. Triggers restart the stream from the file start by re-reading
the first frame header; playback ends when the stream is exhausted.
Samples are mixed into the same signed 12-bit domain as the
oscillator waveforms.

### Sample bank

A channel holds one sample stream, so its playback cursor plays one
sound at a time. The sample bank decouples which sound plays from which
channel plays it: a slot holds a sample's properties (byte source,
format, frame count, resample step), parsed once at load. A scheduled
play carries a slot number, and when the event fires the engine copies
the slot's properties into the target channel's stream before the
retrigger. The copy replaces the header re-read, so no parsing runs in
the render path.

This is what lets several samples share one channel and choke each
other. Playing a slot on a busy channel hard-resets its cursor, cutting
the current sound, and the new slot supplies a different sample, so the
open and closed hi-hat (or any drum pair) coexist on one channel with
distinct sounds. Because the slot travels on the reservation rather
than on the channel's mutable source, two samples scheduled ahead on a
shared channel each still play their own sound, which a per-trigger
`set_sample` could not guarantee under the scheduler's lookahead.

### Flash streaming

`PWMAudio::Stream` plays files too large for RAM (a 5-minute mono
44.1 kHz QOA track is about 5.3 MB against an 8 MB heap). The flash
filesystem region is memory-mapped
([filesystem.md](filesystem.md)), so file bytes are readable at
stable addresses once their locations are known. `FlashFile.extents`
walks the file's LittleFS CTZ skip list once ([littlefs
DESIGN.md][littlefs-design]: block 0 is all data; block index i
begins with ctz(i)+1 list pointers, the first pointing at block i-1)
and emits the data ranges in file order. The render IRQ then reads
straight from XIP through the extent byte source: no RAM buffer, no
feeder task, and playback that keeps running while the Ruby VM is
busy (a long eval starves background tasks, which is why a
Ruby-fed ring was rejected).

Two constraints follow from reading flash behind the filesystem's
back. The file must not be rewritten while attached (LittleFS is
copy-on-write, so writing moves blocks; reads elsewhere and metadata
updates are fine). And a flash erase stalls XIP longer than the
41 ms output buffer, so heavy filesystem writes during playback
cause a dropout.

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
- [QOA][qoa]: the Quite OK Audio format (spec and MIT reference
  implementation); the decoder and the host encoder follow it
- [littlefs DESIGN.md][littlefs-design]: CTZ skip lists, the layout
  FlashFile.extents walks

[rp2350-datasheet]: https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
[pico-sdk]: https://github.com/raspberrypi/pico-sdk
[qoa]: https://qoaformat.org
[littlefs-design]: https://github.com/littlefs-project/littlefs/blob/master/DESIGN.md
