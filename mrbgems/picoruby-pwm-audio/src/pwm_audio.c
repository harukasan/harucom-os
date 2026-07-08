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
#include "byte_source.h"
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

/* Gain slew per output sample. vol_tab tops out at 2899, so a full
 * fade takes about 180 samples (3.6 ms at 50 kHz): fast enough to
 * feel immediate, slow enough to kill the stop click. */
#define PWM_AUDIO_GAIN_STEP 16

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
  /* Output gain ramp. A source's instantaneous value is generally
   * nonzero when it is cut, so an instant start, stop, or mute steps
   * the output and clicks; the mixer slews gain_current toward the
   * target instead and releases the source once a stop ramp reaches
   * zero. */
  bool stopping;
  uint16_t gain_current;
} pwm_audio_channel_t;

static pwm_audio_channel_t channels[PWM_AUDIO_NUM_CHANNELS];

/* Soft clip by tanh approximation (from picoruby-psg, reshaped for
 * the signed mix domain) */
static inline int32_t
soft_clip(int32_t x)
{
  const int32_t knee = 1800;
  int32_t magnitude = x < 0 ? -x : x;
  if (magnitude > knee) {
    int32_t d = magnitude - knee;
    magnitude = knee + (d >> 3) - (d >> 7);
    if (magnitude > 2047) magnitude = 2047;
  }
  return x < 0 ? -magnitude : magnitude;
}

/* The output idles at mid-scale (50 percent PWM duty) and signals mix
 * around it, so starts and stops never move the DC level (a moving DC
 * level thumps through the AC coupling). The bias itself ramps only
 * at init and deinit. */
#define PWM_AUDIO_BIAS_LEVEL 2048
#define PWM_AUDIO_BIAS_STEP  4 /* full bias in ~10 ms */

static int32_t master_bias;
static bool bias_enabled = true;

void
pwm_audio_bias_fade(bool enable)
{
  bias_enabled = enable;
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
 * A channel whose source is a sample streams one mono or stereo file,
 * either QOA (decoded slice by slice in qoa_decoder.c) or WAV holding
 * plain 16-bit PCM (read sample by sample, no decoding). The bytes
 * come through a byte source: a contiguous buffer for in-memory
 * samples (set_sample) or the flash extent map of a LittleFS file
 * (set_stream), so a multi-megabyte track plays with no RAM buffer.
 * This layer detects the format, adds the linear resampler to the
 * output rate, and keeps the one-shot playback state. Data is pulled
 * on demand while mixing, so the read rate stays tiny. A retrigger
 * restarts the stream from the file start. A mono stream mirrors its
 * samples to both sides so the mixer has a single code path. */

typedef enum {
  PWM_AUDIO_SAMPLE_QOA = 0,
  PWM_AUDIO_SAMPLE_PCM16,
} pwm_audio_sample_format_t;

typedef struct {
  /* sample bytes (backing memory owned by the caller) */
  pwm_audio_byte_source_t source;
  uint32_t total_samples;   /* per channel */
  uint32_t phase_increment; /* 16.16 source samples per output sample */
  uint8_t format;           /* pwm_audio_sample_format_t */
  uint8_t channels;         /* 1 or 2 */
  /* PCM16: data chunk position and read cursor (source frames) */
  uint32_t pcm_offset;
  uint32_t pcm_pos;
  qoa_decoder_t decoder;
  /* linear resampler to the output rate */
  uint32_t phase; /* 16.16 position between prev and next */
  int16_t prev_l, prev_r;
  int16_t next_l, next_r;
  bool playing;
  /* Out of data: hold the last value while the stop ramp fades it. */
  bool ended;
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

/* Parse a WAV (RIFF) header and locate the PCM payload. Only mono and
 * stereo 16-bit PCM are accepted. Chunks other than fmt and data are
 * skipped, so files with LIST/INFO metadata still load. */
static bool
wav_parse_header(pwm_audio_byte_source_t *source, uint32_t *samplerate, uint32_t *frames,
                 uint32_t *channels, uint32_t *pcm_offset)
{
  uint32_t length = source->length;
  if (length < 44) return false;
  uint8_t header[12];
  if (!pwm_audio_byte_source_read(source, 0, header, sizeof(header))) return false;
  if (memcmp(header, "RIFF", 4) != 0 || memcmp(header + 8, "WAVE", 4) != 0) return false;

  uint32_t pos = 12;
  bool have_format = false;
  uint16_t wav_channels = 0;
  uint32_t wav_rate = 0;
  while (pos + 8 <= length) {
    uint8_t chunk[8];
    if (!pwm_audio_byte_source_read(source, pos, chunk, sizeof(chunk))) return false;
    uint32_t chunk_size = read_u32le(chunk + 4);
    uint32_t body = pos + 8;
    if (chunk_size > length - body) return false;
    if (memcmp(chunk, "fmt ", 4) == 0 && chunk_size >= 16) {
      uint8_t fmt[16];
      if (!pwm_audio_byte_source_read(source, body, fmt, sizeof(fmt))) return false;
      uint16_t codec = read_u16le(fmt);
      wav_channels = read_u16le(fmt + 2);
      wav_rate = read_u32le(fmt + 4);
      uint16_t bits = read_u16le(fmt + 14);
      if (codec != 1 || bits != 16) return false; /* 16-bit PCM only */
      have_format = true;
    } else if (memcmp(chunk, "data", 4) == 0) {
      if (!have_format || wav_channels < 1 || wav_channels > 2 || wav_rate == 0) return false;
      *samplerate = wav_rate;
      *frames = chunk_size / (2 * wav_channels);
      *channels = wav_channels;
      *pcm_offset = body;
      return *frames > 0;
    }
    pos = body + chunk_size + (chunk_size & 1); /* chunks are word aligned */
  }
  return false;
}

/* Detect the sample format and report its parameters. */
static bool
probe_source(pwm_audio_byte_source_t *source, uint32_t *samplerate, uint32_t *frames,
             uint32_t *channels, uint8_t *format, uint32_t *pcm_offset)
{
  *pcm_offset = 0;
  if (qoa_decoder_parse_header(source, samplerate, frames, channels)) {
    *format = PWM_AUDIO_SAMPLE_QOA;
    return true;
  }
  if (wav_parse_header(source, samplerate, frames, channels, pcm_offset)) {
    *format = PWM_AUDIO_SAMPLE_PCM16;
    return true;
  }
  return false;
}

/* Advance the resampler window by one source frame. */
static bool
stream_pull(pwm_audio_sample_stream_t *stream)
{
  int16_t left, right;
  if (stream->format == PWM_AUDIO_SAMPLE_PCM16) {
    if (stream->pcm_pos >= stream->total_samples) return false;
    uint8_t frame[4];
    uint32_t frame_bytes = 2 * stream->channels;
    uint32_t offset = stream->pcm_offset + stream->pcm_pos * frame_bytes;
    if (!pwm_audio_byte_source_read(&stream->source, offset, frame, frame_bytes)) return false;
    left = (int16_t)read_u16le(frame);
    right = stream->channels == 2 ? (int16_t)read_u16le(frame + 2) : left;
    stream->pcm_pos++;
  } else {
    if (!qoa_decoder_next(&stream->decoder, &left, &right)) return false;
  }
  stream->prev_l = stream->next_l;
  stream->prev_r = stream->next_r;
  stream->next_l = left;
  stream->next_r = right;
  return true;
}

bool
pwm_audio_sample_info(const uint8_t *data, uint32_t length, uint32_t *samplerate,
                      uint32_t *frames, uint32_t *channels)
{
  pwm_audio_byte_source_t source;
  uint8_t format;
  uint32_t pcm_offset;
  pwm_audio_byte_source_memory(&source, data, length);
  return probe_source(&source, samplerate, frames, channels, &format, &pcm_offset);
}

bool
pwm_audio_stream_info(const uint8_t *extent_pairs, uint32_t extent_count,
                      uint32_t total_length, uint32_t *samplerate, uint32_t *frames,
                      uint32_t *channels)
{
  pwm_audio_byte_source_t source;
  uint8_t format;
  uint32_t pcm_offset;
  pwm_audio_byte_source_extents(&source, extent_pairs, extent_count, total_length);
  return probe_source(&source, samplerate, frames, channels, &format, &pcm_offset);
}

/* Validate a byte source and attach it to a channel. */
static bool
attach_source(uint8_t channel, const pwm_audio_byte_source_t *source)
{
  if (channel >= PWM_AUDIO_NUM_CHANNELS) return false;
  uint32_t samplerate, frames, sample_channels, pcm_offset;
  uint8_t format;
  pwm_audio_byte_source_t probe = *source;
  if (!probe_source(&probe, &samplerate, &frames, &sample_channels, &format, &pcm_offset)) {
    return false;
  }
  uint32_t state = pwm_audio_lock();
  pwm_audio_sample_stream_t *stream = &sample_streams[channel];
  stream->playing = false;
  stream->ended = false;
  stream->source = *source;
  stream->total_samples = frames;
  stream->format = format;
  stream->channels = (uint8_t)sample_channels;
  stream->pcm_offset = pcm_offset;
  stream->phase_increment = (uint32_t)(((uint64_t)samplerate << 16) / PWM_AUDIO_SAMPLE_RATE);
  channels[channel].source = PWM_AUDIO_SOURCE_SAMPLE;
  channels[channel].phase_increment = 0; /* silence the oscillator */
  pwm_audio_unlock(state);
  return true;
}

bool
pwm_audio_set_sample(uint8_t channel, const uint8_t *data, uint32_t length)
{
  pwm_audio_byte_source_t source;
  pwm_audio_byte_source_memory(&source, data, length);
  return attach_source(channel, &source);
}

bool
pwm_audio_set_stream(uint8_t channel, const uint8_t *extent_pairs, uint32_t extent_count,
                     uint32_t total_length)
{
  pwm_audio_byte_source_t source;
  pwm_audio_byte_source_extents(&source, extent_pairs, extent_count, total_length);
  return attach_source(channel, &source);
}

/* Restart the stream from the file start. Runs under the lock; also
 * called by the event queue inside the render IRQ. */
static void
play_locked(uint8_t channel, uint8_t volume)
{
  pwm_audio_sample_stream_t *stream = &sample_streams[channel];
  if (channels[channel].source != PWM_AUDIO_SOURCE_SAMPLE || stream->source.length == 0) return;
  if (stream->format == PWM_AUDIO_SAMPLE_PCM16) {
    stream->pcm_pos = 0;
  } else {
    qoa_decoder_reset(&stream->decoder, &stream->source, stream->total_samples,
                      stream->channels);
  }
  stream->phase = 0;
  stream->prev_l = 0;
  stream->prev_r = 0;
  stream->next_l = 0;
  stream->next_r = 0;
  stream->ended = false;
  channels[channel].volume = volume & 0x0F;
  channels[channel].muted = false;
  channels[channel].stopping = false;
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
  int32_t bias_target = bias_enabled ? PWM_AUDIO_BIAS_LEVEL : 0;
  if (master_bias < bias_target) {
    master_bias += PWM_AUDIO_BIAS_STEP;
    if (master_bias > bias_target) master_bias = bias_target;
  } else if (master_bias > bias_target) {
    master_bias -= PWM_AUDIO_BIAS_STEP;
    if (master_bias < bias_target) master_bias = bias_target;
  }

  int32_t mix_l = 0, mix_r = 0;

  for (int i = 0; i < PWM_AUDIO_NUM_CHANNELS; i++) {
    pwm_audio_channel_t *ch = &channels[i];
    int32_t signal_l, signal_r;

    /* Slew the gain toward its target, then release a stopped source
     * once the fade reaches silence. An idle source keeps the target
     * at zero; without this the gain would climb back while silent
     * and the next start would begin at full level instead of fading
     * in. A playing source keeps its target, so a legato set_tone
     * does not dip. */
    bool source_active = ch->source == PWM_AUDIO_SOURCE_SAMPLE
                             ? sample_streams[i].playing
                             : ch->phase_increment != 0;
    uint16_t target =
        (ch->muted || ch->stopping || !source_active) ? 0 : vol_tab[ch->volume & 0x0F];
    uint16_t gain = ch->gain_current;
    if (gain != target) {
      if (gain < target) {
        gain = (target - gain > PWM_AUDIO_GAIN_STEP) ? gain + PWM_AUDIO_GAIN_STEP : target;
      } else {
        gain = (gain - target > PWM_AUDIO_GAIN_STEP) ? gain - PWM_AUDIO_GAIN_STEP : target;
      }
      ch->gain_current = gain;
    }
    if (ch->stopping && gain == 0) {
      ch->stopping = false;
      ch->phase_increment = 0;
      ch->phase = 0;
      sample_streams[i].playing = false;
      sample_streams[i].ended = false;
    }
    if (gain == 0 && target == 0) continue;

    if (ch->source == PWM_AUDIO_SOURCE_SAMPLE) {
      pwm_audio_sample_stream_t *stream = &sample_streams[i];
      if (!stream->playing) continue;

      int32_t phase = (int32_t)stream->phase;
      int32_t sample_l =
          stream->prev_l +
          (int32_t)(((int64_t)(stream->next_l - stream->prev_l) * phase) >> 16);
      int32_t sample_r =
          stream->prev_r +
          (int32_t)(((int64_t)(stream->next_r - stream->prev_r) * phase) >> 16);
      /* Map signed 16-bit to the signed 12-bit mix domain. */
      signal_l = sample_l >> 4;
      signal_r = sample_r >> 4;

      if (!stream->ended) {
        stream->phase += stream->phase_increment;
        while (stream->phase >= 0x10000) {
          stream->phase -= 0x10000;
          if (!stream_pull(stream)) {
            /* Out of data: hold the last value and fade it out, so a
             * sample that does not end at zero still stops without a
             * step. */
            stream->ended = true;
            stream->prev_l = stream->next_l;
            stream->prev_r = stream->next_r;
            ch->stopping = true;
            break;
          }
        }
      }
    } else {
      if (!ch->phase_increment) continue;
      ch->phase += ch->phase_increment;
      signal_l = (int32_t)generate_waveform(ch) - 2048;
      signal_r = signal_l;
    }

    /* Pan acts as balance: 8=center keeps both sides at the same
     * -3 dB point as a centered mono source. */
    uint8_t bal = ch->pan & 0x0F;
    mix_l += (((signal_l * (int32_t)gain) >> 12) * (int32_t)pan_tab_l[bal]) >> 12;
    mix_r += (((signal_r * (int32_t)gain) >> 12) * (int32_t)pan_tab_r[bal]) >> 12;
  }

  /* Soft clip around the bias and scale to the PWM level range
   * (0 to PWM_AUDIO_PWM_WRAP) */
  int32_t level_l = master_bias + soft_clip(mix_l);
  int32_t level_r = master_bias + soft_clip(mix_r);
  if (level_l < 0) level_l = 0;
  if (level_l > 4095) level_l = 4095;
  if (level_r < 0) level_r = 0;
  if (level_r > 4095) level_r = 4095;
  *out_l = (uint16_t)(((uint32_t)level_l * PWM_AUDIO_PWM_WRAP) >> 12);
  *out_r = (uint16_t)(((uint32_t)level_r * PWM_AUDIO_PWM_WRAP) >> 12);
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
  sample_streams[channel].ended = false;
  ch->phase_increment = increment;
  ch->waveform = waveform;
  ch->volume = volume & 0x0F;
  ch->muted = false;
  ch->stopping = false;
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
  pwm_audio_channel_t *ch = &channels[channel];
  /* Fade out instead of cutting; the mixer releases the source once
   * the ramp reaches silence. An already-silent channel releases
   * immediately. */
  if (ch->gain_current == 0) {
    ch->stopping = false;
    ch->phase_increment = 0;
    ch->phase = 0;
    sample_streams[channel].playing = false;
    sample_streams[channel].ended = false;
  } else {
    ch->stopping = true;
  }
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
