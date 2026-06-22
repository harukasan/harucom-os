/*
 * Browser (emscripten) PWM audio port.
 *
 * The synth (src/pwm_audio.c) renders 3 channels into the shared ring buffer
 * pwm_audio_buf. On the board a 22050 Hz timer ISR drains one packed stereo
 * frame per tick into the PWM slices. The browser has no PWM and no ISR, so
 * JavaScript drains the ring instead: a Web Audio ScriptProcessorNode calls
 * harucom_audio_pull() to pop frames and advance the read pointer, while the
 * Ruby userland keeps calling PWMAudio.update (pwm_audio_fill_buffer) to refill.
 *
 * Guarded by __EMSCRIPTEN__ (the wasm build is emcc), matching the other
 * ports/posix wasm ports; picoruby auto-compiles ports/posix under POSIX while
 * ports/rp2350 (pico-sdk PWM) is excluded.
 */

#ifdef __EMSCRIPTEN__

#include <emscripten.h>

#include "pwm_audio.h"

// The synth's PWM duty (0..PWM_AUDIO_PWM_WRAP) is an UNSIGNED waveform whose
// silence is duty 0, not the mid level, so a tone is a positive-only swing with
// a large DC component. Normalize to ~0..2 (full scale) here; the DC-blocking
// high-pass below removes the offset (see AUDIO_DCBLOCK_R).
#define AUDIO_NORM (PWM_AUDIO_PWM_WRAP / 2.0f)

// Reproduce the board's analog output stage per channel:
//  - R28/R29 = 220 ohm + C25/C26 = 220 nF: one-pole RC low-pass, ~3.3 kHz, the
//    PWM reconstruction filter (alpha = dt / (R*C + dt), dt = 1/sample_rate).
//  - C27/C28 = 100 uF AC coupling (~0.16 Hz high-pass with R30/R32): removes the
//    DC. Model it as a DC-blocking one-pole high-pass (a fixed mid subtraction
//    would not work, since silence sits at duty 0, leaving a huge -1.0 offset).
#define AUDIO_RC        (220.0f * 220e-9f)            // R28*C25 seconds
#define AUDIO_DT        (1.0f / PWM_AUDIO_SAMPLE_RATE)
#define AUDIO_LP_ALPHA  (AUDIO_DT / (AUDIO_RC + AUDIO_DT))
#define AUDIO_DCBLOCK_R 0.999f                        // DC-block pole (~3.5 Hz at 22050)

static float lp_l = 0.0f, lp_r = 0.0f;   // RC low-pass state
static float dcx_l = 0.0f, dcy_l = 0.0f; // DC-block state (prev input/output), L
static float dcx_r = 0.0f, dcy_r = 0.0f; // DC-block state, R

// No PWM hardware in the browser. init only resets the ring (the synth state is
// set up by the Ruby PWMAudio.tone/update calls); deinit silences the synth.
void
pwm_audio_init(uint8_t l_pin, uint8_t r_pin)
{
  (void)l_pin;
  (void)r_pin;
  pwm_audio_rd = 0;
  pwm_audio_wr = 0;
}

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

// Drain up to `frames` stereo frames into planar float channels (the layout a
// ScriptProcessorNode's getChannelData wants). Each packed sample holds L in the
// high 16 bits and R in the low 16 bits, both 0..PWM_AUDIO_PWM_WRAP. On underrun
// the remaining frames are silence. Returns the number of real frames produced.
// JS owns the read pointer through this call (the wasm analogue of the board ISR).
EMSCRIPTEN_KEEPALIVE
int
harucom_audio_pull(float *out_l, float *out_r, int frames)
{
  int produced = 0;
  for (int i = 0; i < frames; i++) {
    if (pwm_audio_wr == pwm_audio_rd) {
      // Underrun: the caller asked for more than the ring holds (the JS pump
      // over-pulls to refill its FIFO and discards these silence frames). Emit
      // silence but do NOT advance the filters: running zeros through them would
      // corrupt the lp/dc state and glitch the next real sample on resume.
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

#endif /* __EMSCRIPTEN__ */
