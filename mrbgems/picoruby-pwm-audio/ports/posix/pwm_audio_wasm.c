// Copyright (c) 2026 Shunsuke Michii
//
// Browser (emscripten) PWM audio port.
//
// The synth (src/pwm_audio.c) renders 3 channels into the ring buffer
// pwm_audio_buf. The browser has no PWM and no ISR, so JavaScript drains the
// ring: a Web Audio ScriptProcessorNode calls harucom_audio_pull() to pop
// frames, while Ruby keeps calling PWMAudio.update to refill.

#ifdef __EMSCRIPTEN__

#include <emscripten.h>

#include "pwm_audio.h"

// The synth's PWM duty (0..PWM_AUDIO_PWM_WRAP) is unsigned: silence is duty 0,
// so a tone is a positive-only swing with a large DC component. Normalize to
// ~0..2 here; the DC-blocking high-pass below removes the offset.
#define AUDIO_NORM (PWM_AUDIO_PWM_WRAP / 2.0f)

// Reproduce the board's analog output stage per channel:
//  - R28/R29 = 220 ohm + C25/C26 = 220 nF: one-pole RC low-pass, ~3.3 kHz, the
//    PWM reconstruction filter (alpha = dt / (R*C + dt), dt = 1/sample_rate).
//  - C27/C28 = 100 uF AC coupling (~0.16 Hz high-pass with R30/R32): modeled as
//    a DC-blocking one-pole high-pass (a fixed mid subtraction would not work,
//    since silence sits at duty 0, leaving a huge -1.0 offset). The corner is set
//    to ~3.5 Hz, not the board's 0.16 Hz: the synth waveform is unsigned, so the
//    block must pull that DC out within a note or a loud voice rides up past
//    +-1.0 and clips. The cost is that the DC step at an abrupt note-off (the
//    synth has no release ramp) recovers in tens of ms, an audible click; a
//    synth-side release would be the real fix.
#define AUDIO_RC        (220.0f * 220e-9f)            // R28*C25 seconds
#define AUDIO_DT        (1.0f / PWM_AUDIO_SAMPLE_RATE)
#define AUDIO_LP_ALPHA  (AUDIO_DT / (AUDIO_RC + AUDIO_DT))
#define AUDIO_DCBLOCK_R 0.999f                        // DC-block pole (~3.5 Hz at 22050)

static float lp_l = 0.0f, lp_r = 0.0f;   // RC low-pass state
static float dcx_l = 0.0f, dcy_l = 0.0f; // DC-block state (prev input/output), L
static float dcx_r = 0.0f, dcy_r = 0.0f; // DC-block state, R

// Reset the ring.
void
pwm_audio_init(uint8_t l_pin, uint8_t r_pin)
{
  (void)l_pin;
  (void)r_pin;
  pwm_audio_rd = 0;
  pwm_audio_wr = 0;
}

// Silence the synth.
void
pwm_audio_deinit(void)
{
  pwm_audio_stop_all();
  pwm_audio_rd = 0;
  pwm_audio_wr = 0;
}

EMSCRIPTEN_KEEPALIVE
int
harucom_audio_sample_rate(void)
{
  return PWM_AUDIO_SAMPLE_RATE;
}

// Drain up to `frames` stereo frames into planar float channels (the layout
// ScriptProcessorNode's getChannelData wants). Each packed sample holds L in the
// high 16 bits and R in the low 16 bits. On underrun the rest is silence.
// Returns the number of real frames produced. JS owns the read pointer, the
// wasm analogue of the board ISR.
EMSCRIPTEN_KEEPALIVE
int
harucom_audio_pull(float *out_l, float *out_r, int frames)
{
  int produced = 0;
  for (int i = 0; i < frames; i++) {
    if (pwm_audio_wr == pwm_audio_rd) {
      // Underrun: the JS pump over-pulls to refill its FIFO and discards these
      // silence frames. Emit silence but do NOT advance the filters; running
      // zeros through them would glitch the next real sample on resume.
      out_l[i] = 0.0f;
      out_r[i] = 0.0f;
      continue;
    }
    uint32_t sample = pwm_audio_buf[pwm_audio_rd & PWM_AUDIO_BUF_MASK];
    pwm_audio_rd++;
    float xl = (float)(sample >> 16) / AUDIO_NORM;    // 0..2, DC removed below
    float xr = (float)(sample & 0xFFFF) / AUDIO_NORM;
    // R28/C25 one-pole RC low-pass (PWM reconstruction).
    lp_l += AUDIO_LP_ALPHA * (xl - lp_l);
    lp_r += AUDIO_LP_ALPHA * (xr - lp_r);
    // C27 DC-blocking high-pass: y[n] = x[n] - x[n-1] + R*y[n-1].
    float yl = lp_l - dcx_l + AUDIO_DCBLOCK_R * dcy_l; dcx_l = lp_l; dcy_l = yl;
    float yr = lp_r - dcx_r + AUDIO_DCBLOCK_R * dcy_r; dcx_r = lp_r; dcy_r = yr;
    out_l[i] = yl;
    out_r[i] = yr;
    produced++;
  }
  return produced;
}

// --- Measurement-only helpers (headless spectral analysis) -------------------
// Not used by the browser run loop. They let scripts/measure_audio.cjs capture a
// clean, underrun-free stream of synth output so a DFT can separate the
// fundamental, harmonics and noise, telling synth quantization/aliasing (shared
// with the board) from something the wasm-only path adds.

// Set a channel's tone directly (no Ruby boot needed for measurement).
EMSCRIPTEN_KEEPALIVE
void
harucom_audio_measure_tone(int channel, int frequency, int waveform, int volume)
{
  // The ~2.9 ms attack ramp is discarded by the analysis warmup region, so no
  // need to snap the envelope here.
  pwm_audio_set_tone((uint8_t)channel, (uint32_t)frequency, (uint8_t)waveform,
                     (uint8_t)volume);
}

// Render `total` continuous mono frames (channel L of the mix) into `out` with
// no ring underrun, so the capture is gap-free. mode 0 = raw normalized synth
// duty centered on 0 (the pure digital synth, bit-identical to the board);
// mode 1 = the full analog model (RC LP + DC block). Filters reset each call.
EMSCRIPTEN_KEEPALIVE
int
harucom_audio_measure_pull(float *out, int total, int mode)
{
  lp_l = 0.0f; dcx_l = 0.0f; dcy_l = 0.0f;
  pwm_audio_rd = 0;
  pwm_audio_wr = 0;
  int produced = 0;
  while (produced < total) {
    pwm_audio_fill_buffer();
    if (pwm_audio_wr == pwm_audio_rd) break; // synth produced nothing (no tone)
    while (pwm_audio_wr != pwm_audio_rd && produced < total) {
      uint32_t sample = pwm_audio_buf[pwm_audio_rd & PWM_AUDIO_BUF_MASK];
      pwm_audio_rd++;
      float xl = (float)(sample >> 16) / AUDIO_NORM; // 0..2
      if (mode == 1) {
        lp_l += AUDIO_LP_ALPHA * (xl - lp_l);
        float yl = lp_l - dcx_l + AUDIO_DCBLOCK_R * dcy_l;
        dcx_l = lp_l; dcy_l = yl;
        out[produced] = yl;
      } else {
        out[produced] = xl - 1.0f; // center the unsigned duty on 0
      }
      produced++;
    }
  }
  return produced;
}

#endif /* __EMSCRIPTEN__ */
