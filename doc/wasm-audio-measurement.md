# Audio Measurement Tools

Tools (under [scripts/](../scripts)) for analyzing the PWM synth: one measures
the compiled wasm synth's spectral purity, the other analyzes a recording of the
real board's audio output. The synth C code in
[pwm_audio.c](../mrbgems/picoruby-pwm-audio/src/pwm_audio.c) is shared between
the board and the wasm build, so a synth-level finding from the wasm tool applies
to the RP2350 hardware as well.

## Tools

- [scripts/measure_audio.cjs](../scripts/measure_audio.cjs) — measures the actual
  compiled synth (`build/wasm/harucom.js`) and reports, per tone, the
  fundamental / harmonic / non-harmonic energy split, the loudest non-harmonic
  spurs, a comparison to an ideal band-limited waveform (to quantify aliasing
  vs the numerical floor), and a simulation of the `js/engine/audio.js` JS resampler (to
  see whether 22050 -> 44100/48000 resampling adds non-harmonic energy). It
  captures a clean, continuous, underrun-free stream straight from the shared
  synth via the measurement-only C API below, so synth noise can be separated
  from noise the wasm-only playback path adds.
- [scripts/analyze_recording.py](../scripts/analyze_recording.py) — analyzes a
  recording of the real board's audio output (any ffmpeg-readable file). It
  reports periodic pop / underrun detection (constant-interval clicks point at a
  periodic Core 0 stall starving the audio ISR), the fundamental and pitch, and
  the non-harmonic energy (so PolyBLEP can be confirmed working on the board).
  Used to diagnose the high-note clicks (audio-ISR timing jitter) and the pitch
  error; needs `numpy` and `ffmpeg`.

## Running

```sh
bundle exec rake wasm:build              # build build/wasm/harucom.js first
node scripts/measure_audio.cjs           # measures the compiled wasm synth
python3 scripts/analyze_recording.py recording.wav [--note-hz 440]
```

`measure_audio.cjs` does not boot Ruby (it never calls `harucom_init`), so the
picoruby-wasm gem's DOM-dependent JS init never runs and it works under plain
node. `analyze_recording.py` needs no build (it only reads a recording).

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
  port status, including the audio architecture and the deferred board audio
  work (ISR-jitter clicks, pitch error) that analyze_recording.py drives.
