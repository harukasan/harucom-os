/*
 * picoruby-pwm-audio/src/pwm_audio.c
 *
 * 3-channel waveform synthesizer with phase accumulator.
 * Supports sine, square, triangle, and sawtooth waveforms.
 * All computation is platform-independent; the render pump that calls
 * pwm_audio_render_block() lives in ports/rp2350/pwm_audio_port.c.
 * See doc/pwm-audio.md for the full design.
 */

#include "../include/pwm_audio.h"
#include <string.h>

#if defined(PICORB_VM_MRUBY)
#include "mruby/pwm_audio.c"
#endif

/* --- Sine lookup table (256 entries, 0-4095) --- */
/* One full cycle of a sine wave, offset to unsigned 0-4095 range:
 *   value[i] = (int)(2047.5 + 2047.5 * sin(2*PI*i/256))
 */
static const uint16_t sine_table[256] = {
    2048, 2098, 2148, 2198, 2248, 2298, 2348, 2398, 2447, 2496, 2545, 2594, 2642, 2690, 2737, 2784,
    2831, 2877, 2923, 2968, 3012, 3056, 3100, 3143, 3185, 3226, 3267, 3307, 3346, 3385, 3423, 3460,
    3496, 3531, 3565, 3598, 3630, 3662, 3692, 3722, 3750, 3777, 3804, 3829, 3853, 3876, 3898, 3919,
    3939, 3958, 3975, 3992, 4007, 4021, 4034, 4045, 4056, 4065, 4073, 4080, 4085, 4090, 4093, 4095,
    4095, 4095, 4093, 4090, 4085, 4080, 4073, 4065, 4056, 4045, 4034, 4021, 4007, 3992, 3975, 3958,
    3939, 3919, 3898, 3876, 3853, 3829, 3804, 3777, 3750, 3722, 3692, 3662, 3630, 3598, 3565, 3531,
    3496, 3460, 3423, 3385, 3346, 3307, 3267, 3226, 3185, 3143, 3100, 3056, 3012, 2968, 2923, 2877,
    2831, 2784, 2737, 2690, 2642, 2594, 2545, 2496, 2447, 2398, 2348, 2298, 2248, 2198, 2148, 2098,
    2048, 1997, 1947, 1897, 1847, 1797, 1747, 1697, 1648, 1599, 1550, 1501, 1453, 1405, 1358, 1311,
    1264, 1218, 1172, 1127, 1083, 1039, 995,  952,  910,  869,  828,  788,  749,  710,  672,  635,
    599,  564,  530,  497,  465,  433,  403,  373,  345,  318,  291,  266,  242,  219,  197,  176,
    156,  137,  120,  103,  88,   74,   61,   50,   39,   30,   22,   15,   10,   5,    2,    0,
    0,    0,    2,    5,    10,   15,   22,   30,   39,   50,   61,   74,   88,   103,  120,  137,
    156,  176,  197,  219,  242,  266,  291,  318,  345,  373,  403,  433,  465,  497,  530,  564,
    599,  635,  672,  710,  749,  788,  828,  869,  910,  952,  995,  1039, 1083, 1127, 1172, 1218,
    1264, 1311, 1358, 1405, 1453, 1501, 1550, 1599, 1648, 1697, 1747, 1797, 1847, 1897, 1947, 1997};

/* Volume table: 1.5 dB steps with 3.0 dB headroom for 12-bit range.
 * Copied from picoruby-psg. */
static const uint16_t vol_tab[16] = {0,   258,  307,  365,  434,  516,  613,  728,
                                     865, 1029, 1223, 1453, 1727, 2052, 2439, 2899};

/* Pan tables: 1=L-only, 8=center, 15=R-only.
 * Copied from picoruby-psg. */
static const uint16_t pan_tab_l[16] = {4095, 4095, 4069, 3992, 3865, 3689, 3467, 3202,
                                       2896, 2553, 2179, 1777, 1352, 911,  458,  0};
static const uint16_t pan_tab_r[16] = {0,    0,    458,  911,  1352, 1777, 2179, 2553,
                                       2896, 3202, 3467, 3689, 3865, 3992, 4069, 4095};

/* Channel state */
static pwm_audio_channel_t channels[PWM_AUDIO_NUM_CHANNELS];

/* Soft clip by tanh approximation (from picoruby-psg) */
static inline uint16_t
soft_clip(uint32_t x)
{
  const uint32_t knee = 3600;
  if (x <= knee) return (uint16_t)x;
  uint32_t d = x - knee;
  uint32_t y = knee + ((d >> 3) - (d >> 7));
  return (y > 4095) ? 4095 : (uint16_t)y;
}

static inline uint32_t
generate_waveform(pwm_audio_channel_t *ch)
{
  switch (ch->waveform) {
  case PWM_AUDIO_WAVE_SINE:
    return sine_table[ch->phase >> 24];

  case PWM_AUDIO_WAVE_TRIANGLE: {
    uint32_t idx = ch->phase >> 19;
    idx ^= (idx >> 12);
    uint32_t tri = idx & 0x1FFF;
    return tri >> 1;
  }

  case PWM_AUDIO_WAVE_SAWTOOTH:
    return ch->phase >> 20;

  default: /* PWM_AUDIO_WAVE_SQUARE */
    return (ch->phase >> 31) ? 4095 : 0;
  }
}

void
pwm_audio_calc_sample(uint16_t *out_l, uint16_t *out_r)
{
  uint32_t mix_l = 0, mix_r = 0;

  for (int i = 0; i < PWM_AUDIO_NUM_CHANNELS; i++) {
    pwm_audio_channel_t *ch = &channels[i];

    if (ch->muted || !ch->phase_increment) continue;

    ch->phase += ch->phase_increment;

    uint32_t amp = generate_waveform(ch);

    uint32_t gain = vol_tab[ch->volume & 0x0F];
    amp = (amp * gain) >> 12;

    uint8_t bal = ch->pan & 0x0F;
    mix_l += (amp * pan_tab_l[bal]) >> 12;
    mix_r += (amp * pan_tab_r[bal]) >> 12;
  }

  /* Soft clip and scale to the PWM level range (0 to PWM_AUDIO_PWM_WRAP) */
  *out_l = (uint16_t)((uint32_t)soft_clip(mix_l) * PWM_AUDIO_PWM_WRAP >> 12);
  *out_r = (uint16_t)((uint32_t)soft_clip(mix_r) * PWM_AUDIO_PWM_WRAP >> 12);
}

void
pwm_audio_set_tone(uint8_t channel, uint32_t frequency, uint8_t waveform, uint8_t volume)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return;
  pwm_audio_channel_t *ch = &channels[channel];
  ch->phase_increment =
      frequency ? (uint32_t)(((uint64_t)frequency << 32) / PWM_AUDIO_SAMPLE_RATE) : 0;
  ch->waveform = waveform;
  ch->volume = volume & 0x0F;
  ch->muted = false;
}

void
pwm_audio_set_pan(uint8_t channel, uint8_t pan)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return;
  channels[channel].pan = pan & 0x0F;
}

void
pwm_audio_set_mute(uint8_t channel, bool mute)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return;
  channels[channel].muted = mute;
}

void
pwm_audio_stop_channel(uint8_t channel)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return;
  channels[channel].phase_increment = 0;
  channels[channel].phase = 0;
  channels[channel].muted = true;
}

void
pwm_audio_stop_all(void)
{
  for (int i = 0; i < PWM_AUDIO_NUM_CHANNELS; i++) {
    pwm_audio_stop_channel(i);
  }
}

/* --- Sample buffer and block renderer --- */

/* Aligned to its own byte size so the DMA read ring can wrap on it. */
uint32_t pwm_audio_buf[PWM_AUDIO_BUF_SIZE]
    __attribute__((aligned(PWM_AUDIO_BUF_SIZE * 4)));
bool pwm_audio_l_is_pwm_a = true;

/* Scheduled events, applied at exact sample positions during block
 * rendering. frequency 0 means a channel stop. The queue is mutated
 * with pwm_audio_lock() held; the renderer runs in an IRQ, so a
 * locked writer cannot be interrupted by it. */
#define PWM_AUDIO_EVENT_MAX 32

typedef struct {
  uint64_t when;
  uint32_t frequency;
  uint8_t channel;
  uint8_t waveform;
  uint8_t volume;
  bool used;
} pwm_audio_event_t;

static pwm_audio_event_t events[PWM_AUDIO_EVENT_MAX];

bool
pwm_audio_schedule(uint64_t when, uint8_t channel, uint32_t frequency,
                   uint8_t waveform, uint8_t volume)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return false;
  uint32_t state = pwm_audio_lock();
  for (int i = 0; i < PWM_AUDIO_EVENT_MAX; i++) {
    if (events[i].used) continue;
    events[i].when = when;
    events[i].frequency = frequency;
    events[i].channel = channel;
    events[i].waveform = waveform;
    events[i].volume = volume;
    events[i].used = true;
    pwm_audio_unlock(state);
    return true;
  }
  pwm_audio_unlock(state);
  return false;
}

void
pwm_audio_cancel_scheduled(uint8_t channel)
{
  uint32_t state = pwm_audio_lock();
  for (int i = 0; i < PWM_AUDIO_EVENT_MAX; i++) {
    if (events[i].used && events[i].channel == channel) {
      events[i].used = false;
    }
  }
  pwm_audio_unlock(state);
}

static void
apply_event(const pwm_audio_event_t *event)
{
  if (event->frequency) {
    pwm_audio_set_tone(event->channel, event->frequency, event->waveform, event->volume);
  } else {
    pwm_audio_stop_channel(event->channel);
  }
}

/* Pack an L/R pair in PWM CC register format: channel A in the low
 * half-word, channel B in the high half-word. */
static inline uint32_t
pack_cc(uint16_t l, uint16_t r)
{
  if (pwm_audio_l_is_pwm_a) {
    return ((uint32_t)r << 16) | l;
  }
  return ((uint32_t)l << 16) | r;
}

void
pwm_audio_render_block(uint64_t start_sample, uint32_t *dst, uint32_t count)
{
  uint32_t i = 0;
  while (i < count) {
    uint64_t now = start_sample + i;
    uint32_t run = count - i;
    /* Apply due events, then shorten the run to the next event inside
     * this block so it lands on its exact sample. */
    for (int e = 0; e < PWM_AUDIO_EVENT_MAX; e++) {
      pwm_audio_event_t *event = &events[e];
      if (!event->used) continue;
      if (event->when <= now) {
        apply_event(event);
        event->used = false;
      } else if (event->when < start_sample + count) {
        uint32_t until = (uint32_t)(event->when - now);
        if (until < run) run = until;
      }
    }
    while (run > 0) {
      uint16_t l, r;
      pwm_audio_calc_sample(&l, &r);
      dst[i] = pack_cc(l, r);
      i++;
      run--;
    }
  }
}
