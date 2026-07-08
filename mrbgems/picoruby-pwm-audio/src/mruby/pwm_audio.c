/*
 * picoruby-pwm-audio/src/mruby/pwm_audio.c
 *
 * Ruby bindings for PWMAudio module.
 */

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/presym.h>

#include "../../include/pwm_audio.h"

/* PWMAudio.init(l_pin, r_pin) */
static mrb_value
mrb_pwm_audio_init(mrb_state *mrb, mrb_value self)
{
  mrb_int l_pin, r_pin;
  mrb_get_args(mrb, "ii", &l_pin, &r_pin);
  pwm_audio_init((uint8_t)l_pin, (uint8_t)r_pin);
  return mrb_nil_value();
}

/* PWMAudio.tone(channel, frequency, waveform, volume) */
static mrb_value
mrb_pwm_audio_tone(mrb_state *mrb, mrb_value self)
{
  mrb_int channel, frequency, waveform, volume;
  mrb_get_args(mrb, "iiii", &channel, &frequency, &waveform, &volume);
  pwm_audio_set_tone((uint8_t)channel, (uint32_t)frequency, (uint8_t)waveform, (uint8_t)volume);
  return mrb_nil_value();
}

/* PWMAudio.pan(channel, pan) */
static mrb_value
mrb_pwm_audio_pan(mrb_state *mrb, mrb_value self)
{
  mrb_int channel, pan;
  mrb_get_args(mrb, "ii", &channel, &pan);
  pwm_audio_set_pan((uint8_t)channel, (uint8_t)pan);
  return mrb_nil_value();
}

/* PWMAudio.mute(channel, flag) */
static mrb_value
mrb_pwm_audio_mute(mrb_state *mrb, mrb_value self)
{
  mrb_int channel;
  mrb_bool flag;
  mrb_get_args(mrb, "ib", &channel, &flag);
  pwm_audio_set_mute((uint8_t)channel, flag);
  return mrb_nil_value();
}

/* PWMAudio.stop(channel) */
static mrb_value
mrb_pwm_audio_stop(mrb_state *mrb, mrb_value self)
{
  mrb_int channel;
  mrb_get_args(mrb, "i", &channel);
  pwm_audio_stop_channel((uint8_t)channel);
  return mrb_nil_value();
}

/* PWMAudio.stop_all */
static mrb_value
mrb_pwm_audio_stop_all(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  pwm_audio_stop_all();
  return mrb_nil_value();
}

/* PWMAudio.update: kept for compatibility. The engine renders
 * autonomously in C, so there is nothing to fill from Ruby. */
static mrb_value
mrb_pwm_audio_update(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  return mrb_nil_value();
}

/* PWMAudio.sample_clock: playback position in samples (monotonic) */
static mrb_value
mrb_pwm_audio_sample_clock(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  return mrb_int_value(mrb, (mrb_int)pwm_audio_sample_clock());
}

/* PWMAudio.tone_at(sample, channel, frequency, waveform, volume)
 * Schedule a tone start at an absolute sample position. Returns false
 * when the event queue is full. */
static mrb_value
mrb_pwm_audio_tone_at(mrb_state *mrb, mrb_value self)
{
  mrb_int sample, channel, frequency, waveform, volume;
  mrb_get_args(mrb, "iiiii", &sample, &channel, &frequency, &waveform, &volume);
  bool ok = pwm_audio_schedule((uint64_t)sample, (uint8_t)channel, (uint32_t)frequency,
                               (uint8_t)waveform, (uint8_t)volume);
  return mrb_bool_value(ok);
}

/* PWMAudio.stop_at(sample, channel): schedule a channel stop */
static mrb_value
mrb_pwm_audio_stop_at(mrb_state *mrb, mrb_value self)
{
  mrb_int sample, channel;
  mrb_get_args(mrb, "ii", &sample, &channel);
  bool ok = pwm_audio_schedule((uint64_t)sample, (uint8_t)channel, 0, 0, 0);
  return mrb_bool_value(ok);
}

/* PWMAudio.stats:
 * [min_lead_samples, max_pump_gap_us, drift_now, drift_min] */
static mrb_value
mrb_pwm_audio_stats(mrb_state *mrb, mrb_value self)
{
  int32_t min_lead, drift_now, drift_min;
  uint32_t max_gap_us;
  pwm_audio_stats(&min_lead, &max_gap_us, &drift_now, &drift_min);
  mrb_value ary = mrb_ary_new_capa(mrb, 4);
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, min_lead));
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, (mrb_int)max_gap_us));
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, drift_now));
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, drift_min));
  return ary;
}

/* PWMAudio.cancel_scheduled(channel): drop pending events for a channel */
static mrb_value
mrb_pwm_audio_cancel_scheduled(mrb_state *mrb, mrb_value self)
{
  mrb_int channel;
  mrb_get_args(mrb, "i", &channel);
  pwm_audio_cancel_scheduled((uint8_t)channel);
  return mrb_nil_value();
}

/* PWMAudio.deinit */
static mrb_value
mrb_pwm_audio_deinit(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  pwm_audio_deinit();
  return mrb_nil_value();
}

void
mrb_picoruby_pwm_audio_gem_init(mrb_state *mrb)
{
  struct RClass *mod = mrb_define_module_id(mrb, MRB_SYM(PWMAudio));

  mrb_define_const_id(mrb, mod, MRB_SYM(SAMPLE_RATE), mrb_fixnum_value(PWM_AUDIO_SAMPLE_RATE));
  mrb_define_const_id(mrb, mod, MRB_SYM(SINE), mrb_fixnum_value(PWM_AUDIO_WAVE_SINE));
  mrb_define_const_id(mrb, mod, MRB_SYM(SQUARE), mrb_fixnum_value(PWM_AUDIO_WAVE_SQUARE));
  mrb_define_const_id(mrb, mod, MRB_SYM(TRIANGLE), mrb_fixnum_value(PWM_AUDIO_WAVE_TRIANGLE));
  mrb_define_const_id(mrb, mod, MRB_SYM(SAWTOOTH), mrb_fixnum_value(PWM_AUDIO_WAVE_SAWTOOTH));

  mrb_define_module_function_id(mrb, mod, MRB_SYM(init), mrb_pwm_audio_init, MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(tone), mrb_pwm_audio_tone, MRB_ARGS_REQ(4));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(pan), mrb_pwm_audio_pan, MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(mute), mrb_pwm_audio_mute, MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(stop), mrb_pwm_audio_stop, MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(stop_all), mrb_pwm_audio_stop_all,
                                MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM(update), mrb_pwm_audio_update, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM(sample_clock), mrb_pwm_audio_sample_clock,
                                MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM(tone_at), mrb_pwm_audio_tone_at,
                                MRB_ARGS_REQ(5));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(stop_at), mrb_pwm_audio_stop_at,
                                MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(cancel_scheduled),
                                mrb_pwm_audio_cancel_scheduled, MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(stats), mrb_pwm_audio_stats, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM(deinit), mrb_pwm_audio_deinit, MRB_ARGS_NONE());
}

void
mrb_picoruby_pwm_audio_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
