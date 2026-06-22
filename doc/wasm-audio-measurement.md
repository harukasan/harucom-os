# wasm Audio Measurement Tools

Headless spectral analysis tools for the PWM synth used in the wasm build. They
capture a clean, continuous, underrun-free stream straight from the shared synth
C code and run a DFT on it, so synth noise (quantization, aliasing) can be
separated from noise added by the wasm-only playback path (JS resampler,
AudioWorklet flow control). The synth C code in
[pwm_audio.c](../mrbgems/picoruby-pwm-audio/src/pwm_audio.c) is shared with the
board, so any synth-level finding applies to the RP2350 hardware as well.

## Tools

- [wasm/measure_audio.cjs](../wasm/measure_audio.cjs) — measures the actual
  compiled synth (`build/wasm/harucom.js`) and reports, per tone, the
  fundamental / harmonic / non-harmonic energy split, the loudest non-harmonic
  spurs, a comparison to an ideal band-limited waveform (to quantify aliasing
  vs the numerical floor), and a simulation of the `index.html` JS resampler (to
  see whether 22050 -> 44100/48000 resampling adds non-harmonic energy).
- [wasm/proto_antialias.cjs](../wasm/proto_antialias.cjs) — a self-contained
  prototype that reproduces the synth's exact 32-bit phase math (verified
  bit-identical to `pwm_audio.c`) and compares anti-aliasing methods (naive,
  PolyBLEP 2-point, BLEP-table, oversample Nx, ideal) across notes G3..C7. Used
  to choose PolyBLEP 2-point as the cheapest method that reaches "Famicom clean"
  without an ISR/DVI cost.

## Running

```sh
bundle exec rake wasm:build   # build build/wasm/harucom.js first
node wasm/measure_audio.cjs    # measures the compiled synth
node wasm/proto_antialias.cjs  # standalone, no build needed
```

`measure_audio.cjs` does not boot Ruby (it never calls `harucom_init`), so the
picoruby-wasm gem's DOM-dependent JS init never runs and it works under plain
node. `proto_antialias.cjs` reimplements the phase math in JS and needs no
build.

## C API

Defined in
[pwm_audio_wasm.c](../mrbgems/picoruby-pwm-audio/ports/posix/pwm_audio_wasm.c),
guarded by `#ifdef __EMSCRIPTEN__` and exported via the `wasm:build` emcc
exports. They are measurement-only and never run on the browser run loop.

### harucom_audio_measure_tone

```c
void harucom_audio_measure_tone(int channel, int frequency, int waveform, int volume);
```

Sets a channel's tone directly without booting Ruby. The ~2.9 ms attack ramp is
discarded by the analysis warmup region, so the envelope does not need to be
snapped.

### harucom_audio_measure_pull

```c
int harucom_audio_measure_pull(float *out, int total, int mode);
```

Renders `total` continuous mono frames (channel L of the mix) into `out` with no
ring underrun, so the captured waveform is gap-free. `mode 0` returns the raw
normalized synth duty centered on 0 (the pure digital synth, bit-identical to
the board); `mode 1` returns the full analog model (RC low-pass + DC block), the
board-equivalent analog output. The filters are reset at the start of each call
so the warmup region is deterministic.

## References

- [doc/masterplan/wasm-resume-plan.md](masterplan/wasm-resume-plan.md): wasm
  port status, including the audio architecture and the PolyBLEP anti-aliasing
  decision these tools informed.
