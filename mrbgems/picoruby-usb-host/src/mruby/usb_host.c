#include <mruby.h>
#include <mruby/array.h>
#include <mruby/presym.h>

#include "usb_host.h"

/*
 * USB::Host.init
 */
static mrb_value
mrb_usb_host_init(mrb_state *mrb, mrb_value klass)
{
  usb_host_init();
  return mrb_nil_value();
}

/*
 * USB::Host.task
 */
static mrb_value
mrb_usb_host_task(mrb_state *mrb, mrb_value klass)
{
  usb_host_task();
  return mrb_nil_value();
}

/*
 * USB::Host.keyboard_connected?
 */
static mrb_value
mrb_usb_host_keyboard_connected(mrb_state *mrb, mrb_value klass)
{
  return mrb_bool_value(usb_host_keyboard_connected());
}

/*
 * USB::Host.keyboard_keycodes -> Array of Integers (up to 6)
 */
static mrb_value
mrb_usb_host_keyboard_keycodes(mrb_state *mrb, mrb_value klass)
{
  const uint8_t *keycodes = usb_host_keyboard_keycodes();
  mrb_value ary = mrb_ary_new_capa(mrb, 6);
  for (int i = 0; i < 6; i++) {
    if (keycodes[i] != 0) {
      mrb_ary_push(mrb, ary, mrb_fixnum_value(keycodes[i]));
    }
  }
  return ary;
}

/*
 * USB::Host.keyboard_modifier -> Integer
 */
static mrb_value
mrb_usb_host_keyboard_modifier(mrb_state *mrb, mrb_value klass)
{
  return mrb_fixnum_value(usb_host_keyboard_modifier());
}

void
mrb_picoruby_usb_host_gem_init(mrb_state *mrb)
{
  struct RClass *module_USB = mrb_define_module_id(mrb, MRB_SYM(USB));

  struct RClass *module_Host = mrb_define_module_under_id(mrb, module_USB, MRB_SYM(Host));

  mrb_define_module_function_id(mrb, module_Host, MRB_SYM(init), mrb_usb_host_init,
                                MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, module_Host, MRB_SYM(task), mrb_usb_host_task,
                                MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, module_Host, MRB_SYM_Q(keyboard_connected),
                                mrb_usb_host_keyboard_connected, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, module_Host, MRB_SYM(keyboard_keycodes),
                                mrb_usb_host_keyboard_keycodes, MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, module_Host, MRB_SYM(keyboard_modifier),
                                mrb_usb_host_keyboard_modifier, MRB_ARGS_NONE());
}

void
mrb_picoruby_usb_host_gem_final(mrb_state *mrb)
{
}
