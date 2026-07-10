# Synth

Sample synthesis as Ruby code, shared between the board and the host.
A render block written in a small DSP vocabulary produces a 16-bit
mono WAV String that plugs straight into
[PWMAudio::Sample](pwm-audio.md); the same file
([synth.rb](../rootfs/lib/synth.rb)) runs on the board's mruby VM, in
the host test VM, and under host CRuby, so one definition serves
sound design, file generation, and tests. The board's drum kit is
defined this way ([synth/drum_kit.rb](../rootfs/lib/synth/drum_kit.rb)),
which keeps third-party audio out of the repository entirely.

## Ruby API

Module: `Synth` (in [rootfs/lib/synth.rb](../rootfs/lib/synth.rb))

- [Synth.render](#synthrenderrate-seed-block---string)
- [Render vocabulary](#render-vocabulary)
- [Synth::Buffer](#synthbuffer)
- [Synth::DrumKit](#synthdrumkit)

```ruby
require "synth"

kick = PWMAudio::Sample.new(Synth.render(rate: 44100) {
  sweep(0.28, from: 160, to: 44, curve: 28, decay: 12) +
    noise(0.02, decay: 300).highpass(900) * 0.5
})
channel = audio.channel(0)
channel.source = kick
channel.play
```

### Synth.render(rate:, seed:, &block) -> String

Evaluate the block against a render context and return a WAV String.
The block uses the vocabulary below and must return a `Synth::Buffer`;
the result is peak-normalized and tail-faded.

Rendering is deterministic: the same seed produces the same bytes on
a given backend (noise comes from a seeded xorshift, not the system
RNG), so generated files are reproducible and testable. Pass
`seed: RNG.random_int` on the board for a different noise take each
time.

The per-sample loops run through a small fixed kernel set with two
interchangeable backends: `Synth::Native` (the picoruby-synth-native
mrbgem, single-precision C) and `Synth::Kernels` (pure Ruby, the
backend on host CRuby where the gem does not exist). The kernels
(curves, oscillators, noise, elementwise math, a generic biquad, WAV
packing) carry no musical meaning and do not change when sounds do;
everything musical, from filter coefficients to the drum definitions,
lives only in the Ruby layer, so editing a sound applies to every
platform at once. Backends produce the same sound but not the same
bits (float vs double); a test keeps them within tolerance of each
other. Interpreted rendering costs seconds per drum on the board, the
C kernels tens of milliseconds.

### Render vocabulary

Inside the block, these produce `Synth::Buffer` values:

- `sweep(seconds, from:, to: from, curve: 0, decay:)`: damped sine
  with an exponential pitch sweep from `from` Hz to `to` Hz (`curve`
  is the sweep rate, `decay` the amplitude decay); kicks, toms, and
  snare shells
- `noise(seconds, decay: 0)`: white noise burst
- `metallic(seconds, decay:, partials: Synth::HIHAT_PARTIALS)`: a
  stack of square partials, the classic metallic hihat source
- `silence(seconds)`

### Synth::Buffer

A mono float signal with a sample rate. Operations return new
Buffers:

- `+` mixes (the result spans the longer operand), `*` scales
- `highpass(cutoff)` / `lowpass(cutoff)`: one-pole filters
- `bandpass(center, q:)`: resonant biquad
- `env(decay, at: 0, cut: nil, level: 1)`: exponential envelope
  starting `at` seconds in, silenced past `cut` seconds; summing
  several `env` of one source builds multi-attack shapes like
  handclaps
- `normalize(peak: 0.9)`, `fade_tail(ms: 4)`, `to_wav`

### Synth::DrumKit

The board's drum kit as named definitions: `bd`, `sd`, `hh`, `oh`,
`cp`, `lt`, `ht`, `rim`.

- `DrumKit.names -> Array`
- `DrumKit.render(name, rate: 44100, seed: ...) -> String`
- `DrumKit.define(name) { ... }` registers a definition

`scripts/gen_drumkit.rb` renders these to
[rootfs/data/drums/](../rootfs/data/drums) on the host; the board can
render the same definitions directly:

```ruby
require "synth"
require "synth/drum_kit"
snare = PWMAudio::Sample.new(Synth::DrumKit.render("sd"))
```

## References

- [PWM Audio](pwm-audio.md): the playback engine consuming the
  rendered WAV Strings
