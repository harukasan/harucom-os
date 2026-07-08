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
#include "qoa_decoder.h"
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

/* Channel state: the oscillator plus the properties shared by both
 * source kinds (volume, pan, mute). The sample stream state lives in
 * sample_streams[] below. Mutated under pwm_audio_lock() so the
 * render IRQ never sees a half-applied update. */
typedef enum {
  PWM_AUDIO_SOURCE_OSC = 0,
  PWM_AUDIO_SOURCE_SAMPLE,
} pwm_audio_source_t;

typedef struct {
  uint32_t phase;
  uint32_t phase_increment;
  uint8_t waveform; /* pwm_audio_waveform_t */
  uint8_t volume;   /* 0-15 */
  uint8_t pan;      /* 0-15: 0=L, 8=center, 15=R */
  uint8_t source;   /* pwm_audio_source_t */
  bool muted;
} pwm_audio_channel_t;

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

/* --- Sample playback (QOA and WAV) ---
 *
 * A channel whose source is a sample streams one mono file, either
 * QOA (decoded slice by slice in qoa_decoder.c) or WAV holding plain
 * 16-bit PCM (read sample by sample, no decoding). This layer detects
 * the format, adds the linear resampler to the output rate, and keeps
 * the one-shot playback state. Data is pulled on demand while mixing,
 * so only the file bytes are held in memory and the PSRAM read rate
 * stays tiny. A retrigger restarts the stream from the file start. */

typedef enum {
  PWM_AUDIO_SAMPLE_QOA = 0,
  PWM_AUDIO_SAMPLE_PCM16,
} pwm_audio_sample_format_t;

typedef struct {
  /* loaded sample (file bytes, owned by the caller) */
  const uint8_t *data;
  uint32_t length;
  uint32_t total_samples;
  uint32_t phase_increment; /* 16.16 source samples per output sample */
  uint8_t format;           /* pwm_audio_sample_format_t */
  /* PCM16: data chunk position and read cursor (source samples) */
  uint32_t pcm_offset;
  uint32_t pcm_pos;
  qoa_decoder_t decoder;
  /* linear resampler to the output rate */
  uint32_t phase; /* 16.16 position between prev and next */
  int16_t prev;
  int16_t next;
  bool playing;
} pwm_audio_sample_stream_t;

static pwm_audio_sample_stream_t sample_streams[PWM_AUDIO_NUM_CHANNELS];

static inline uint32_t
read_u32le(const uint8_t *p)
{
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline uint16_t
read_u16le(const uint8_t *p)
{
  return (uint16_t)(p[0] | (p[1] << 8));
}

/* Parse a WAV (RIFF) header and locate the PCM payload. Only mono
 * 16-bit PCM is accepted. Chunks other than fmt and data are skipped,
 * so files with LIST/INFO metadata still load. */
static bool
wav_parse_header(const uint8_t *data, uint32_t length, uint32_t *samplerate, uint32_t *frames,
                 uint32_t *pcm_offset)
{
  if (length < 44) return false;
  if (memcmp(data, "RIFF", 4) != 0 || memcmp(data + 8, "WAVE", 4) != 0) return false;

  uint32_t pos = 12;
  bool have_format = false;
  uint16_t wav_channels = 0;
  uint32_t wav_rate = 0;
  while (pos + 8 <= length) {
    const uint8_t *chunk = data + pos;
    uint32_t chunk_size = read_u32le(chunk + 4);
    uint32_t body = pos + 8;
    if (chunk_size > length - body) return false;
    if (memcmp(chunk, "fmt ", 4) == 0 && chunk_size >= 16) {
      uint16_t codec = read_u16le(data + body);
      wav_channels = read_u16le(data + body + 2);
      wav_rate = read_u32le(data + body + 4);
      uint16_t bits = read_u16le(data + body + 14);
      if (codec != 1 || bits != 16) return false; /* 16-bit PCM only */
      have_format = true;
    } else if (memcmp(chunk, "data", 4) == 0) {
      if (!have_format || wav_channels != 1 || wav_rate == 0) return false;
      *samplerate = wav_rate;
      *frames = chunk_size / 2;
      *pcm_offset = body;
      return *frames > 0;
    }
    pos = body + chunk_size + (chunk_size & 1); /* chunks are word aligned */
  }
  return false;
}

/* Advance the resampler window by one source sample. */
static bool
stream_pull(pwm_audio_sample_stream_t *stream)
{
  int16_t sample;
  if (stream->format == PWM_AUDIO_SAMPLE_PCM16) {
    if (stream->pcm_pos >= stream->total_samples) return false;
    const uint8_t *p = stream->data + stream->pcm_offset + stream->pcm_pos * 2;
    sample = (int16_t)read_u16le(p);
    stream->pcm_pos++;
  } else {
    if (!qoa_decoder_next(&stream->decoder, &sample)) return false;
  }
  stream->prev = stream->next;
  stream->next = sample;
  return true;
}

bool
pwm_audio_sample_info(const uint8_t *data, uint32_t length, uint32_t *samplerate,
                      uint32_t *frames)
{
  uint32_t pcm_offset;
  if (qoa_decoder_parse_header(data, length, samplerate, frames)) return true;
  return wav_parse_header(data, length, samplerate, frames, &pcm_offset);
}

bool
pwm_audio_set_sample(uint8_t channel, const uint8_t *data, uint32_t length)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return false;
  uint32_t samplerate, frames;
  uint8_t format;
  uint32_t pcm_offset = 0;
  if (qoa_decoder_parse_header(data, length, &samplerate, &frames)) {
    format = PWM_AUDIO_SAMPLE_QOA;
  } else if (wav_parse_header(data, length, &samplerate, &frames, &pcm_offset)) {
    format = PWM_AUDIO_SAMPLE_PCM16;
  } else {
    return false;
  }
  uint32_t state = pwm_audio_lock();
  pwm_audio_sample_stream_t *stream = &sample_streams[channel];
  stream->playing = false;
  stream->data = data;
  stream->length = length;
  stream->total_samples = frames;
  stream->format = format;
  stream->pcm_offset = pcm_offset;
  stream->phase_increment = (uint32_t)(((uint64_t)samplerate << 16) / PWM_AUDIO_SAMPLE_RATE);
  channels[channel].source = PWM_AUDIO_SOURCE_SAMPLE;
  channels[channel].phase_increment = 0; /* silence the oscillator */
  pwm_audio_unlock(state);
  return true;
}

/* Restart the stream from the file start. Runs under the lock; also
 * called by the event queue inside the render IRQ. */
static void
play_locked(uint8_t channel, uint8_t volume)
{
  pwm_audio_sample_stream_t *stream = &sample_streams[channel];
  if (channels[channel].source != PWM_AUDIO_SOURCE_SAMPLE || stream->data == NULL) return;
  if (stream->format == PWM_AUDIO_SAMPLE_PCM16) {
    stream->pcm_pos = 0;
  } else {
    qoa_decoder_reset(&stream->decoder, stream->data, stream->length, stream->total_samples);
  }
  stream->phase = 0;
  stream->prev = 0;
  stream->next = 0;
  channels[channel].volume = volume & 0x0F;
  channels[channel].muted = false;
  /* Prime the resampler: the first outputs interpolate from silence
   * into the first source sample. */
  stream->playing = stream_pull(stream);
}

void
pwm_audio_play(uint8_t channel, uint8_t volume)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return;
  uint32_t state = pwm_audio_lock();
  play_locked(channel, volume);
  pwm_audio_unlock(state);
}

void
pwm_audio_calc_sample(uint16_t *out_l, uint16_t *out_r)
{
  uint32_t mix_l = 0, mix_r = 0;

  for (int i = 0; i < PWM_AUDIO_NUM_CHANNELS; i++) {
    pwm_audio_channel_t *ch = &channels[i];
    uint32_t amp;

    if (ch->muted) continue;

    if (ch->source == PWM_AUDIO_SOURCE_SAMPLE) {
      pwm_audio_sample_stream_t *stream = &sample_streams[i];
      if (!stream->playing) continue;

      int32_t sample =
          stream->prev +
          (int32_t)(((int64_t)(stream->next - stream->prev) * (int32_t)stream->phase) >> 16);
      /* Map signed 16-bit to the unipolar 12-bit mix domain (same
       * convention as the tone waveforms). */
      amp = (uint32_t)(sample + 32768) >> 4;

      stream->phase += stream->phase_increment;
      while (stream->phase >= 0x10000) {
        stream->phase -= 0x10000;
        if (!stream_pull(stream)) {
          stream->playing = false;
          break;
        }
      }
    } else {
      if (!ch->phase_increment) continue;
      ch->phase += ch->phase_increment;
      amp = generate_waveform(ch);
    }

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
  uint32_t increment =
      frequency ? (uint32_t)(((uint64_t)frequency << 32) / PWM_AUDIO_SAMPLE_RATE) : 0;
  uint32_t state = pwm_audio_lock();
  ch->source = PWM_AUDIO_SOURCE_OSC;
  sample_streams[channel].playing = false;
  ch->phase_increment = increment;
  ch->waveform = waveform;
  ch->volume = volume & 0x0F;
  ch->muted = false;
  pwm_audio_unlock(state);
}

void
pwm_audio_set_pan(uint8_t channel, uint8_t pan)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return;
  uint32_t state = pwm_audio_lock();
  channels[channel].pan = pan & 0x0F;
  pwm_audio_unlock(state);
}

void
pwm_audio_set_mute(uint8_t channel, bool mute)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return;
  uint32_t state = pwm_audio_lock();
  channels[channel].muted = mute;
  pwm_audio_unlock(state);
}

void
pwm_audio_stop_channel(uint8_t channel)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return;
  uint32_t state = pwm_audio_lock();
  channels[channel].phase_increment = 0;
  channels[channel].phase = 0;
  channels[channel].muted = true;
  sample_streams[channel].playing = false;
  pwm_audio_unlock(state);
}

void
pwm_audio_stop_all(void)
{
  /* One critical section so no rendered block sees a partial stop.
   * The nested locks in the per-channel stops are save/restore safe. */
  uint32_t state = pwm_audio_lock();
  for (int i = 0; i < PWM_AUDIO_NUM_CHANNELS; i++) {
    pwm_audio_stop_channel(i);
  }
  pwm_audio_unlock(state);
}

/* --- Sample buffer and block renderer --- */

/* Aligned to its own byte size so the DMA read ring can wrap on it. */
uint32_t pwm_audio_buf[PWM_AUDIO_BUF_SIZE]
    __attribute__((aligned(PWM_AUDIO_BUF_SIZE * 4)));
bool pwm_audio_l_is_pwm_a = true;

/* Scheduled events, applied at exact sample positions during block
 * rendering. Tone events with frequency 0 mean a channel stop; play
 * events trigger the channel's sample. The queue is mutated with
 * pwm_audio_lock() held; the renderer runs in an IRQ, so a locked
 * writer cannot be interrupted by it. */
#define PWM_AUDIO_EVENT_MAX 32

enum {
  PWM_AUDIO_EVENT_TONE = 0,
  PWM_AUDIO_EVENT_PLAY,
};

typedef struct {
  uint64_t when;
  uint32_t sequence; /* schedule order, tie-break for equal when */
  uint32_t frequency;
  uint8_t kind;
  uint8_t channel;
  uint8_t waveform;
  uint8_t volume;
  bool used;
} pwm_audio_event_t;

static pwm_audio_event_t events[PWM_AUDIO_EVENT_MAX];
static uint32_t event_sequence;

static bool
schedule_event(uint64_t when, uint8_t kind, uint8_t channel, uint32_t frequency,
               uint8_t waveform, uint8_t volume)
{
  uint32_t state = pwm_audio_lock();
  for (int i = 0; i < PWM_AUDIO_EVENT_MAX; i++) {
    if (events[i].used) continue;
    events[i].when = when;
    events[i].sequence = event_sequence++;
    events[i].frequency = frequency;
    events[i].kind = kind;
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

bool
pwm_audio_schedule(uint64_t when, uint8_t channel, uint32_t frequency,
                   uint8_t waveform, uint8_t volume)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return false;
  return schedule_event(when, PWM_AUDIO_EVENT_TONE, channel, frequency, waveform, volume);
}

bool
pwm_audio_play_schedule(uint64_t when, uint8_t channel, uint8_t volume)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return false;
  return schedule_event(when, PWM_AUDIO_EVENT_PLAY, channel, 0, 0, volume);
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

/* Order events by position, then by schedule order for ties, so
 * same-sample events (e.g. a stop and a retrigger) apply as the
 * caller issued them. */
static bool
event_is_before(const pwm_audio_event_t *a, const pwm_audio_event_t *b)
{
  if (a->when != b->when) return a->when < b->when;
  return (int32_t)(a->sequence - b->sequence) < 0;
}

static void
apply_event(const pwm_audio_event_t *event)
{
  if (event->kind == PWM_AUDIO_EVENT_PLAY) {
    play_locked(event->channel, event->volume);
  } else if (event->frequency) {
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
    /* Apply due events oldest first so an overdue tone/stop pair for
     * one channel resolves as scheduled. */
    for (;;) {
      pwm_audio_event_t *due = NULL;
      for (int e = 0; e < PWM_AUDIO_EVENT_MAX; e++) {
        pwm_audio_event_t *event = &events[e];
        if (!event->used || event->when > now) continue;
        if (!due || event_is_before(event, due)) due = event;
      }
      if (!due) break;
      apply_event(due);
      due->used = false;
    }
    /* Shorten the run to the next event inside this block so it lands
     * on its exact sample. */
    for (int e = 0; e < PWM_AUDIO_EVENT_MAX; e++) {
      pwm_audio_event_t *event = &events[e];
      if (!event->used) continue;
      if (event->when < start_sample + count) {
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
