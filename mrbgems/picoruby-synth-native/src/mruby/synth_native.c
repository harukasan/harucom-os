/*
 * picoruby-synth/src/mruby/synth_native.c
 *
 * Synth::Native: a small, fixed set of numeric array kernels behind
 * the Synth render DSL (rootfs/lib/synth.rb). The kernels carry no
 * musical meaning: curves, oscillators, noise, elementwise math, a
 * generic biquad, and WAV packing. Everything musical (the sweep
 * formula, filter coefficients, drum definitions) stays in Ruby, so
 * sounds are edited in one place and this file never needs to change
 * with them. The Ruby side implements the same kernels as a fallback
 * for host CRuby.
 */

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/presym.h>
#include <mruby/string.h>

#include <math.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  uint32_t length;
  float data[];
} synth_native_t;

/* Exponential decays run as a multiply recurrence (one expf for the
 * per-sample ratio) instead of calling expf per sample. Rounding error
 * grows with the sample count, so the exact value is recomputed every
 * RESYNC samples, keeping the drift below a few 16-bit LSB while the
 * expf cost stays at 0.1% of the samples. */
#define SYNTH_EXP_RESYNC 1024

/* sinf costs hundreds of cycles on the M33; a 256-entry quarter-step
 * table with linear interpolation is accurate to about 2e-5, well
 * under one 16-bit LSB. Filled on first use to keep this file free of
 * generated data. */
#define SINE_TABLE_SIZE 256
static float sine_table[SINE_TABLE_SIZE + 1];
static int sine_table_ready = 0;

static void
sine_table_init(void)
{
  if (sine_table_ready) return;
  for (int i = 0; i <= SINE_TABLE_SIZE; i++) {
    sine_table[i] = sinf(2.0f * (float)M_PI * (float)i / (float)SINE_TABLE_SIZE);
  }
  sine_table_ready = 1;
}

static void
synth_native_free(mrb_state *mrb, void *ptr)
{
  mrb_free(mrb, ptr);
}

static const struct mrb_data_type synth_native_type = {
  "SynthNative", synth_native_free,
};

static synth_native_t *
native_alloc(mrb_state *mrb, uint32_t length)
{
  synth_native_t *native =
      (synth_native_t *)mrb_malloc(mrb, sizeof(synth_native_t) + sizeof(float) * length);
  native->length = length;
  return native;
}

static mrb_value
native_wrap(mrb_state *mrb, synth_native_t *native)
{
  struct RClass *module_Synth = mrb_module_get_id(mrb, MRB_SYM(Synth));
  struct RClass *class_Native = mrb_class_get_under_id(mrb, module_Synth, MRB_SYM(Native));
  return mrb_obj_value(Data_Wrap_Struct(mrb, class_Native, &synth_native_type, native));
}

static synth_native_t *
native_unwrap(mrb_state *mrb, mrb_value value)
{
  return (synth_native_t *)mrb_data_get_ptr(mrb, value, &synth_native_type);
}

/* Synth::Native.constant(length, value) */
static mrb_value
mrb_native_constant(mrb_state *mrb, mrb_value self)
{
  mrb_int length;
  mrb_float value;
  mrb_get_args(mrb, "if", &length, &value);
  synth_native_t *out = native_alloc(mrb, (uint32_t)length);
  float v = (float)value;
  for (mrb_int i = 0; i < length; i++) out->data[i] = v;
  return native_wrap(mrb, out);
}

/* Synth::Native.exp_curve(length, rate, base, amount, curve):
 * base + amount * exp(-t * curve) */
static mrb_value
mrb_native_exp_curve(mrb_state *mrb, mrb_value self)
{
  mrb_int length, rate;
  mrb_float base, amount, curve;
  mrb_get_args(mrb, "iifff", &length, &rate, &base, &amount, &curve);
  synth_native_t *out = native_alloc(mrb, (uint32_t)length);
  float rate_f = (float)rate;
  float base_f = (float)base, amount_f = (float)amount, curve_f = (float)curve;
  float ratio = expf(-curve_f / rate_f);
  float e = 1.0f;
  for (mrb_int i = 0; i < length; i++) {
    if ((i & (SYNTH_EXP_RESYNC - 1)) == 0) {
      e = expf(-((float)i / rate_f) * curve_f);
    }
    out->data[i] = base_f + amount_f * e;
    e *= ratio;
  }
  return native_wrap(mrb, out);
}

/* Synth::Native.envelope(length, rate, decay, at, cut, level):
 * zero before `at` seconds, exp(-t * decay) * level after it,
 * silenced past `cut` seconds relative to `at` (cut < 0: no cut).
 * Offsets round to whole samples. */
static mrb_value
mrb_native_envelope(mrb_state *mrb, mrb_value self)
{
  mrb_int length, rate;
  mrb_float decay, at, cut, level;
  mrb_get_args(mrb, "iiffff", &length, &rate, &decay, &at, &cut, &level);
  synth_native_t *out = native_alloc(mrb, (uint32_t)length);
  memset(out->data, 0, sizeof(float) * (size_t)length);
  int64_t start = (int64_t)((double)rate * (double)at + 0.5);
  int64_t stop = length - 1;
  if (cut >= 0) {
    int64_t cut_samples = (int64_t)((double)rate * (double)cut + 0.5);
    if (start + cut_samples < stop) stop = start + cut_samples;
  }
  float rate_f = (float)rate;
  float decay_f = (float)decay, level_f = (float)level;
  float ratio = expf(-decay_f / rate_f);
  float e = level_f;
  for (int64_t i = start; i >= 0 && i <= stop; i++) {
    int64_t k = i - start;
    if ((k & (SYNTH_EXP_RESYNC - 1)) == 0) {
      e = expf(-((float)k / rate_f) * decay_f) * level_f;
    }
    out->data[i] = e;
    e *= ratio;
  }
  return native_wrap(mrb, out);
}

/* Synth::Native.noise(length, state) -> [Native, new_state]
 * Same xorshift32 as Synth::Random in rootfs/lib/synth.rb, so both
 * backends draw the same sequence from the same seed. */
static mrb_value
mrb_native_noise(mrb_state *mrb, mrb_value self)
{
  mrb_int length, state;
  mrb_get_args(mrb, "ii", &length, &state);
  synth_native_t *out = native_alloc(mrb, (uint32_t)length);
  uint32_t rng = (uint32_t)state;
  for (mrb_int i = 0; i < length; i++) {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    out->data[i] = (float)((double)rng / 2147483648.0 - 1.0);
  }
  mrb_value result = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, result, native_wrap(mrb, out));
  mrb_ary_push(mrb, result, mrb_int_value(mrb, (mrb_int)rng));
  return result;
}

/* oscillate(rate, shape): phase-accumulated oscillator over this
 * buffer as a per-sample frequency curve. shape 0 = sine,
 * 1 = square. */
static mrb_value
mrb_native_oscillate(mrb_state *mrb, mrb_value self)
{
  mrb_int rate, shape;
  mrb_get_args(mrb, "ii", &rate, &shape);
  synth_native_t *freqs = native_unwrap(mrb, self);
  synth_native_t *out = native_alloc(mrb, freqs->length);
  float rate_f = (float)rate;
  if (shape == 0) {
    /* Phase runs in turns and wraps every sample, which also keeps
     * float precision constant where the old unbounded radian
     * accumulator degraded over long buffers. */
    sine_table_init();
    float phase = 0.0f;
    for (uint32_t i = 0; i < freqs->length; i++) {
      phase += freqs->data[i] / rate_f;
      phase -= (float)(int32_t)phase;
      if (phase < 0.0f) phase += 1.0f;
      float pos = phase * (float)SINE_TABLE_SIZE;
      int32_t idx = (int32_t)pos;
      float frac = pos - (float)idx;
      out->data[i] = sine_table[idx] + (sine_table[idx + 1] - sine_table[idx]) * frac;
    }
  } else {
    /* Integer phase in 1/2^32 turns, like the xorshift noise: exact
     * and identical in every backend. A float phase accumulator
     * drifts between float widths (boxed VM floats truncate mantissa
     * bits) and a drifted square flips whole samples at its edges. */
    uint32_t acc = 0;
    double scale = 4294967296.0 / (double)rate;
    for (uint32_t i = 0; i < freqs->length; i++) {
      uint32_t step = (uint32_t)(int64_t)((double)freqs->data[i] * scale + 0.5);
      acc += step;
      out->data[i] = acc < 0x80000000u ? 1.0f : -1.0f;
    }
  }
  return native_wrap(mrb, out);
}

/* mix(other): sum spanning the longer operand */
static mrb_value
mrb_native_mix(mrb_state *mrb, mrb_value self)
{
  mrb_value other_value;
  mrb_get_args(mrb, "o", &other_value);
  synth_native_t *a = native_unwrap(mrb, self);
  synth_native_t *b = native_unwrap(mrb, other_value);
  uint32_t n = a->length > b->length ? a->length : b->length;
  synth_native_t *out = native_alloc(mrb, n);
  for (uint32_t i = 0; i < n; i++) {
    float va = i < a->length ? a->data[i] : 0.0f;
    float vb = i < b->length ? b->data[i] : 0.0f;
    out->data[i] = va + vb;
  }
  return native_wrap(mrb, out);
}

/* multiply(other): elementwise product over this buffer's span
 * (the other operand reads as zero past its end) */
static mrb_value
mrb_native_multiply(mrb_state *mrb, mrb_value self)
{
  mrb_value other_value;
  mrb_get_args(mrb, "o", &other_value);
  synth_native_t *a = native_unwrap(mrb, self);
  synth_native_t *b = native_unwrap(mrb, other_value);
  synth_native_t *out = native_alloc(mrb, a->length);
  for (uint32_t i = 0; i < a->length; i++) {
    float vb = i < b->length ? b->data[i] : 0.0f;
    out->data[i] = a->data[i] * vb;
  }
  return native_wrap(mrb, out);
}

/* gain(value) */
static mrb_value
mrb_native_gain(mrb_state *mrb, mrb_value self)
{
  mrb_float gain;
  mrb_get_args(mrb, "f", &gain);
  synth_native_t *a = native_unwrap(mrb, self);
  synth_native_t *out = native_alloc(mrb, a->length);
  float g = (float)gain;
  for (uint32_t i = 0; i < a->length; i++) {
    out->data[i] = a->data[i] * g;
  }
  return native_wrap(mrb, out);
}

/* biquad(b0, b1, b2, a1, a2): direct form 1, coefficients computed by
 * the Ruby side */
static mrb_value
mrb_native_biquad(mrb_state *mrb, mrb_value self)
{
  mrb_float b0, b1, b2, a1, a2;
  mrb_get_args(mrb, "fffff", &b0, &b1, &b2, &a1, &a2);
  synth_native_t *a = native_unwrap(mrb, self);
  synth_native_t *out = native_alloc(mrb, a->length);
  float fb0 = (float)b0, fb1 = (float)b1, fb2 = (float)b2;
  float fa1 = (float)a1, fa2 = (float)a2;
  float x1 = 0.0f, x2 = 0.0f, y1 = 0.0f, y2 = 0.0f;
  for (uint32_t i = 0; i < a->length; i++) {
    float x = a->data[i];
    float y = fb0 * x + fb1 * x1 + fb2 * x2 - fa1 * y1 - fa2 * y2;
    out->data[i] = y;
    x2 = x1;
    x1 = x;
    y2 = y1;
    y1 = y;
  }
  return native_wrap(mrb, out);
}

/* peak -> Float */
static mrb_value
mrb_native_peak(mrb_state *mrb, mrb_value self)
{
  synth_native_t *a = native_unwrap(mrb, self);
  float max = 0.0f;
  for (uint32_t i = 0; i < a->length; i++) {
    float v = a->data[i];
    if (v < 0) v = -v;
    if (v > max) max = v;
  }
  return mrb_float_value(mrb, (mrb_float)max);
}

/* fade_tail(samples): linear ramp to zero over the last n samples */
static mrb_value
mrb_native_fade_tail(mrb_state *mrb, mrb_value self)
{
  mrb_int n;
  mrb_get_args(mrb, "i", &n);
  synth_native_t *a = native_unwrap(mrb, self);
  synth_native_t *out = native_alloc(mrb, a->length);
  memcpy(out->data, a->data, sizeof(float) * (size_t)a->length);
  if (n > (mrb_int)out->length) n = out->length;
  uint32_t start = out->length - (uint32_t)n;
  for (mrb_int i = 0; i < n; i++) {
    out->data[start + i] *= 1.0f - (float)(i + 1) / (float)n;
  }
  return native_wrap(mrb, out);
}

/* to_wav(rate) -> String (16-bit mono WAV) */
static mrb_value
mrb_native_to_wav(mrb_state *mrb, mrb_value self)
{
  mrb_int rate;
  mrb_get_args(mrb, "i", &rate);
  synth_native_t *a = native_unwrap(mrb, self);
  uint32_t pcm_bytes = a->length * 2;
  mrb_value wav = mrb_str_new(mrb, NULL, 44 + pcm_bytes);
  uint8_t *out = (uint8_t *)RSTRING_PTR(wav);

  memcpy(out, "RIFF", 4);
  uint32_t riff = 36 + pcm_bytes;
  out[4] = (uint8_t)riff;
  out[5] = (uint8_t)(riff >> 8);
  out[6] = (uint8_t)(riff >> 16);
  out[7] = (uint8_t)(riff >> 24);
  memcpy(out + 8, "WAVEfmt ", 8);
  out[16] = 16; out[17] = 0; out[18] = 0; out[19] = 0; /* fmt size */
  out[20] = 1; out[21] = 0;                            /* PCM */
  out[22] = 1; out[23] = 0;                            /* mono */
  uint32_t r = (uint32_t)rate;
  out[24] = (uint8_t)r;
  out[25] = (uint8_t)(r >> 8);
  out[26] = (uint8_t)(r >> 16);
  out[27] = (uint8_t)(r >> 24);
  uint32_t byte_rate = r * 2;
  out[28] = (uint8_t)byte_rate;
  out[29] = (uint8_t)(byte_rate >> 8);
  out[30] = (uint8_t)(byte_rate >> 16);
  out[31] = (uint8_t)(byte_rate >> 24);
  out[32] = 2; out[33] = 0;   /* block align */
  out[34] = 16; out[35] = 0;  /* bits */
  memcpy(out + 36, "data", 4);
  out[40] = (uint8_t)pcm_bytes;
  out[41] = (uint8_t)(pcm_bytes >> 8);
  out[42] = (uint8_t)(pcm_bytes >> 16);
  out[43] = (uint8_t)(pcm_bytes >> 24);

  uint8_t *pcm = out + 44;
  for (uint32_t i = 0; i < a->length; i++) {
    float v = a->data[i];
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    int32_t s = (int32_t)lroundf(v * 32767.0f);
    pcm[i * 2] = (uint8_t)s;
    pcm[i * 2 + 1] = (uint8_t)(s >> 8);
  }
  return wav;
}

/* length -> Integer */
static mrb_value
mrb_native_length(mrb_state *mrb, mrb_value self)
{
  synth_native_t *a = native_unwrap(mrb, self);
  return mrb_int_value(mrb, (mrb_int)a->length);
}

/* to_a -> Array of Float (slow; for tests and inspection) */
static mrb_value
mrb_native_to_a(mrb_state *mrb, mrb_value self)
{
  synth_native_t *a = native_unwrap(mrb, self);
  mrb_value ary = mrb_ary_new_capa(mrb, (mrb_int)a->length);
  for (uint32_t i = 0; i < a->length; i++) {
    mrb_ary_push(mrb, ary, mrb_float_value(mrb, (mrb_float)a->data[i]));
  }
  return ary;
}

void
mrb_picoruby_synth_native_gem_init(mrb_state *mrb)
{
  struct RClass *module_Synth = mrb_define_module_id(mrb, MRB_SYM(Synth));
  struct RClass *class_Native =
      mrb_define_class_under_id(mrb, module_Synth, MRB_SYM(Native), mrb->object_class);
  MRB_SET_INSTANCE_TT(class_Native, MRB_TT_CDATA);

  mrb_define_class_method_id(mrb, class_Native, MRB_SYM(constant), mrb_native_constant,
                             MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Native, MRB_SYM(exp_curve), mrb_native_exp_curve,
                             MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Native, MRB_SYM(envelope), mrb_native_envelope,
                             MRB_ARGS_REQ(6));
  mrb_define_class_method_id(mrb, class_Native, MRB_SYM(noise), mrb_native_noise,
                             MRB_ARGS_REQ(2));

  mrb_define_method_id(mrb, class_Native, MRB_SYM(oscillate), mrb_native_oscillate,
                       MRB_ARGS_REQ(2));
  mrb_define_method_id(mrb, class_Native, MRB_SYM(mix), mrb_native_mix, MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, class_Native, MRB_SYM(multiply), mrb_native_multiply,
                       MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, class_Native, MRB_SYM(gain), mrb_native_gain, MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, class_Native, MRB_SYM(biquad), mrb_native_biquad,
                       MRB_ARGS_REQ(5));
  mrb_define_method_id(mrb, class_Native, MRB_SYM(peak), mrb_native_peak, MRB_ARGS_NONE());
  mrb_define_method_id(mrb, class_Native, MRB_SYM(fade_tail), mrb_native_fade_tail,
                       MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, class_Native, MRB_SYM(to_wav), mrb_native_to_wav, MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, class_Native, MRB_SYM(length), mrb_native_length, MRB_ARGS_NONE());
  mrb_define_method_id(mrb, class_Native, MRB_SYM(to_a), mrb_native_to_a, MRB_ARGS_NONE());
}

void
mrb_picoruby_synth_native_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
