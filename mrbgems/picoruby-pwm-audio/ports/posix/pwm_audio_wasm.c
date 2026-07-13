// Copyright (c) 2026 Shunsuke Michii
//
// Browser (emscripten) PWM audio port for the wrap-paced mixer engine.
//
// The board renders samples ahead of a DMA reader into pwm_audio_buf and paces
// output with a PWM slice. The browser has no DMA and no ISR: JavaScript pulls
// frames on demand from a Web Audio node, so this port renders exactly the
// samples JavaScript asks for (pwm_audio_render_block) and treats the pulled
// position as the playback clock. There is no rendered-ahead lead, so the
// immediate-change fast path (rewind/refill) is a no-op here.

#ifdef __EMSCRIPTEN__

#include <emscripten.h>

#include "pwm_audio.h"

// The mixer's PWM duty (0..PWM_AUDIO_PWM_WRAP) is unsigned: silence idles at the
// bias level (mid scale), so a tone is a swing around a large DC component.
// Normalize to ~0..2 here; the DC-blocking high-pass below removes the offset.
#define AUDIO_NORM (PWM_AUDIO_PWM_WRAP / 2.0f)

// Reproduce the board's analog output stage per channel:
//  - R28/R29 = 220 ohm + C25/C26 = 220 nF: one-pole RC low-pass, ~3.3 kHz, the
//    PWM reconstruction filter (alpha = dt / (R*C + dt), dt = 1/sample_rate).
//  - C27/C28 = 100 uF AC coupling: modeled as a DC-blocking one-pole high-pass.
//    The corner is set to ~3.5 Hz (not the board's 0.16 Hz) so the unsigned
//    waveform's DC is pulled out within a note instead of riding up and clipping.
#define AUDIO_RC        (220.0f * 220e-9f)            // R28*C25 seconds
#define AUDIO_DT        (1.0f / PWM_AUDIO_SAMPLE_RATE)
#define AUDIO_LP_ALPHA  (AUDIO_DT / (AUDIO_RC + AUDIO_DT))
#define AUDIO_DCBLOCK_R 0.999f                        // DC-block pole (~3.5 Hz)

static float lp_l = 0.0f, lp_r = 0.0f;   // RC low-pass state
static float dcx_l = 0.0f, dcy_l = 0.0f; // DC-block state (prev input/output), L
static float dcx_r = 0.0f, dcy_r = 0.0f; // DC-block state, R

// Playback position in samples. JavaScript advances it by pulling; it is also
// the clock the scheduler compares scheduled events against.
static uint64_t render_position = 0;

// --- Platform contract (the parts the RP2350 port keeps in pwm_audio_port.c) -

// Single-threaded browser: rendering and state changes never interleave, so the
// render-IRQ critical section is a no-op.
uint32_t pwm_audio_lock(void) { return 0; }
void pwm_audio_unlock(uint32_t state) { (void)state; }

uint64_t pwm_audio_sample_clock(void) { return render_position; }

// On-demand rendering cannot underrun and does not pace against a wall clock, so
// report a healthy, drift-free state.
void
pwm_audio_stats(int32_t *min_lead, uint32_t *max_gap_us, int32_t *drift_now,
                int32_t *drift_min)
{
  if (min_lead) *min_lead = (int32_t)PWM_AUDIO_BUF_SIZE;
  if (max_gap_us) *max_gap_us = 0;
  if (drift_now) *drift_now = 0;
  if (drift_min) *drift_min = 0;
}

// No rendered-ahead lead to flush: an immediate change already takes effect on
// the next pull, which is one audio block away.
void pwm_audio_rewind_lead(void) {}
void pwm_audio_refill_lead(void) {}

// Center all channels (the zero-initialized pan is L-only), reset the timeline
// and filters, and ramp the idle bias up like the board does at init.
void
pwm_audio_init(uint8_t l_pin, uint8_t r_pin)
{
  (void)l_pin;
  (void)r_pin;
  // Pack L in the high half-word, R in the low half-word (harucom_audio_pull
  // unpacks with L = word >> 16).
  pwm_audio_l_is_pwm_a = false;
  for (int i = 0; i < PWM_AUDIO_NUM_CHANNELS; i++) {
    pwm_audio_set_pan(i, 8);
  }
  render_position = 0;
  lp_l = lp_r = 0.0f;
  dcx_l = dcy_l = dcx_r = dcy_r = 0.0f;
  pwm_audio_bias_fade(true);
}

// Silence the mixer.
void
pwm_audio_deinit(void)
{
  pwm_audio_stop_all();
}

EMSCRIPTEN_KEEPALIVE
int
harucom_audio_sample_rate(void)
{
  return PWM_AUDIO_SAMPLE_RATE;
}

// Reproduce the board's analog stage for one packed CC sample: RC low-pass then
// DC-blocking high-pass, per channel. Advances the filter state.
static inline void
filter_sample(uint32_t word, float *out_l, float *out_r)
{
  float xl = (float)(word >> 16) / AUDIO_NORM;    // 0..2, DC removed below
  float xr = (float)(word & 0xFFFF) / AUDIO_NORM;
  lp_l += AUDIO_LP_ALPHA * (xl - lp_l);
  lp_r += AUDIO_LP_ALPHA * (xr - lp_r);
  float yl = lp_l - dcx_l + AUDIO_DCBLOCK_R * dcy_l; dcx_l = lp_l; dcy_l = yl;
  float yr = lp_r - dcx_r + AUDIO_DCBLOCK_R * dcy_r; dcx_r = lp_r; dcy_r = yr;
  *out_l = yl;
  *out_r = yr;
}

// Render `frames` stereo frames on demand into planar float channels (the layout
// ScriptProcessorNode's getChannelData wants). The mixer renders in CC-register
// format (L high, R low here); apply the analog model and advance the clock.
// Never underruns, so it always produces `frames`. JS owns the pull cadence, the
// wasm analogue of the board's DMA reader.
EMSCRIPTEN_KEEPALIVE
int
harucom_audio_pull(float *out_l, float *out_r, int frames)
{
  uint32_t chunk[256];
  int done = 0;
  while (done < frames) {
    int n = frames - done;
    if (n > (int)(sizeof(chunk) / sizeof(chunk[0]))) n = (int)(sizeof(chunk) / sizeof(chunk[0]));
    pwm_audio_render_block(render_position, chunk, (uint32_t)n);
    render_position += (uint64_t)n;
    for (int i = 0; i < n; i++) {
      filter_sample(chunk[i], &out_l[done + i], &out_r[done + i]);
    }
    done += n;
  }
  return frames;
}

// --- Measurement-only helpers (headless spectral analysis) -------------------
// Not used by the browser run loop. They let scripts/measure_audio.cjs capture a
// clean, underrun-free stream of mixer output so a DFT can separate the
// fundamental, harmonics and noise, telling synth quantization/aliasing (shared
// with the board) from something the wasm-only path adds.

// Set a channel's tone directly (no Ruby boot needed for measurement).
EMSCRIPTEN_KEEPALIVE
void
harucom_audio_measure_tone(int channel, int frequency, int waveform, int volume)
{
  pwm_audio_set_tone((uint8_t)channel, (uint32_t)frequency, (uint8_t)waveform,
                     (uint8_t)volume);
}

// Render `total` continuous mono frames (channel L of the mix) into `out` with
// no ring underrun, so the capture is gap-free. mode 0 = raw normalized mixer
// duty centered on 0 (the pure digital synth, bit-identical to the board);
// mode 1 = the full analog model (RC LP + DC block). Filters and the timeline
// reset each call.
EMSCRIPTEN_KEEPALIVE
int
harucom_audio_measure_pull(float *out, int total, int mode)
{
  lp_l = 0.0f; dcx_l = 0.0f; dcy_l = 0.0f;
  render_position = 0;
  uint32_t chunk[256];
  int done = 0;
  while (done < total) {
    int n = total - done;
    if (n > (int)(sizeof(chunk) / sizeof(chunk[0]))) n = (int)(sizeof(chunk) / sizeof(chunk[0]));
    pwm_audio_render_block(render_position, chunk, (uint32_t)n);
    render_position += (uint64_t)n;
    for (int i = 0; i < n; i++) {
      float xl = (float)(chunk[i] >> 16) / AUDIO_NORM; // 0..2
      if (mode == 1) {
        lp_l += AUDIO_LP_ALPHA * (xl - lp_l);
        float yl = lp_l - dcx_l + AUDIO_DCBLOCK_R * dcy_l;
        dcx_l = lp_l; dcy_l = yl;
        out[done + i] = yl;
      } else {
        out[done + i] = xl - 1.0f; // center the unsigned duty on 0
      }
    }
    done += n;
  }
  return total;
}

#endif /* __EMSCRIPTEN__ */
