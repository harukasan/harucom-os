/*
 * picoruby-dmx/src/mruby/dmx.c
 *
 * Ruby bindings for the DMX module.
 */

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/presym.h>

#include "../../include/dmx.h"

/* DMX.init */
static mrb_value
mrb_dmx_init(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  dmx_init();
  return mrb_nil_value();
}

/* DMX.start */
static mrb_value
mrb_dmx_start(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  dmx_start();
  return mrb_nil_value();
}

/* DMX.stop */
static mrb_value
mrb_dmx_stop(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  dmx_stop();
  return mrb_nil_value();
}

/* DMX.set(channel, value) */
static mrb_value
mrb_dmx_set(mrb_state *mrb, mrb_value self)
{
  mrb_int channel, value;
  mrb_get_args(mrb, "ii", &channel, &value);
  if (value < 0) value = 0;
  if (255 < value) value = 255;
  dmx_set((uint16_t)channel, (uint8_t)value);
  return mrb_nil_value();
}

/* DMX.set_range(channel, values) */
static mrb_value
mrb_dmx_set_range(mrb_state *mrb, mrb_value self)
{
  mrb_int channel;
  mrb_value values;
  uint8_t buffer[DMX_SLOTS];
  mrb_get_args(mrb, "iA", &channel, &values);
  mrb_int count = RARRAY_LEN(values);
  if (DMX_SLOTS < count) count = DMX_SLOTS;
  for (mrb_int i = 0; i < count; i++) {
    mrb_value v = mrb_ary_ref(mrb, values, i);
    if (!mrb_integer_p(v)) {
      mrb_raise(mrb, E_TYPE_ERROR, "set_range values must be Integers");
    }
    mrb_int value = mrb_integer(v);
    if (value < 0) value = 0;
    if (255 < value) value = 255;
    buffer[i] = (uint8_t)value;
  }
  dmx_set_range((uint16_t)channel, buffer, (uint16_t)count);
  return mrb_nil_value();
}

/* DMX.get(channel) -> Integer */
static mrb_value
mrb_dmx_get(mrb_state *mrb, mrb_value self)
{
  mrb_int channel;
  mrb_get_args(mrb, "i", &channel);
  return mrb_fixnum_value(dmx_get((uint16_t)channel));
}

/* DMX.blackout */
static mrb_value
mrb_dmx_blackout(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  dmx_blackout();
  return mrb_nil_value();
}

/* DMX.active_slots = count */
static mrb_value
mrb_dmx_set_active_slots(mrb_state *mrb, mrb_value self)
{
  mrb_int count;
  mrb_get_args(mrb, "i", &count);
  if (count < 1) count = 1;
  if (DMX_SLOTS < count) count = DMX_SLOTS;
  dmx_set_active_slots((uint16_t)count);
  return mrb_fixnum_value(count);
}

/* DMX.frame_count -> Integer */
static mrb_value
mrb_dmx_frame_count(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  return mrb_fixnum_value((mrb_int)dmx_frame_count());
}

/* DMX.keepalive */
static mrb_value
mrb_dmx_keepalive(mrb_state *mrb, mrb_value self)
{
  (void)mrb;
  dmx_keepalive();
  return mrb_nil_value();
}

/* DMX.deadman_ms = ms */
static mrb_value
mrb_dmx_set_deadman_ms(mrb_state *mrb, mrb_value self)
{
  mrb_int ms;
  mrb_get_args(mrb, "i", &ms);
  if (ms < 0) ms = 0;
  dmx_set_deadman_ms((uint32_t)ms);
  return mrb_fixnum_value(ms);
}

void
mrb_picoruby_dmx_gem_init(mrb_state *mrb)
{
  struct RClass *mod = mrb_define_module_id(mrb, MRB_SYM(DMX));

  mrb_define_module_function_id(mrb, mod, MRB_SYM(init), mrb_dmx_init, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM(start), mrb_dmx_start, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM(stop), mrb_dmx_stop, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM(set), mrb_dmx_set, MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(set_range), mrb_dmx_set_range,
                                MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(get), mrb_dmx_get, MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(blackout), mrb_dmx_blackout, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM_E(active_slots), mrb_dmx_set_active_slots,
                                MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, mod, MRB_SYM(frame_count), mrb_dmx_frame_count,
                                MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM(keepalive), mrb_dmx_keepalive,
                                MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, mod, MRB_SYM_E(deadman_ms), mrb_dmx_set_deadman_ms,
                                MRB_ARGS_REQ(1));
}

void
mrb_picoruby_dmx_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
