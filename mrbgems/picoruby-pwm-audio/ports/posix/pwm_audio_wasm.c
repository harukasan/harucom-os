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

// PWM duty (0..PWM_AUDIO_PWM_WRAP) is unsigned and centered near WRAP/2; map it
// to a normalized float in roughly [-1, 1] for the Web Audio output.
#define AUDIO_MID (PWM_AUDIO_PWM_WRAP / 2.0f)

// The board reconstructs the PWM output through a one-pole RC low-pass per
// channel: R28/R29 = 220 ohm in series, C25/C26 = 220 nF to ground, giving a
// cutoff of 1/(2*pi*R*C) ~= 3.3 kHz. Reproduce it as a one-pole IIR so the
// browser timbre matches the hardware (square/sawtooth voices lose their harsh
// upper harmonics). alpha = dt / (R*C + dt), dt = 1 / sample_rate. The series
// C27/R30/R32 stage is only DC blocking, already handled by the AUDIO_MID
// subtraction below, so no extra high-pass is needed.
#define AUDIO_RC       (220.0f * 220e-9f)            // R28*C25 seconds
#define AUDIO_DT       (1.0f / PWM_AUDIO_SAMPLE_RATE)
#define AUDIO_LP_ALPHA (AUDIO_DT / (AUDIO_RC + AUDIO_DT))

static float lp_l = 0.0f, lp_r = 0.0f; // one-pole filter state, persists across pulls

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
    float xl, xr;
    if (pwm_audio_wr == pwm_audio_rd) {
      xl = 0.0f; // underrun: feed silence through the filter so it decays smoothly
      xr = 0.0f;
    } else {
      uint32_t sample = pwm_audio_buf[pwm_audio_rd & PWM_AUDIO_BUF_MASK];
      pwm_audio_rd++;
      xl = ((float)(sample >> 16) - AUDIO_MID) / AUDIO_MID;
      xr = ((float)(sample & 0xFFFF) - AUDIO_MID) / AUDIO_MID;
      produced++;
    }
    // One-pole RC low-pass, matching the board's analog reconstruction filter.
    lp_l += AUDIO_LP_ALPHA * (xl - lp_l);
    lp_r += AUDIO_LP_ALPHA * (xr - lp_r);
    out_l[i] = lp_l;
    out_r[i] = lp_r;
  }
  return produced;
}

#endif /* __EMSCRIPTEN__ */
