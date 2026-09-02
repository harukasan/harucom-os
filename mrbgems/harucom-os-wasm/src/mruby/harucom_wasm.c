/*
 * Ruby-visible classes for the browser build. Included from src/harucom_wasm.c.
 */

#include "mruby/variable.h"
#include "mruby/presym.h"

/* The pads the on-screen D-pads drive, which must match Board::PAD0_PIN and
 * PAD1_PIN in rootfs/lib/board/pad.rb. */
#define HARUCOM_PAD0_PIN 28

/* ADC pad shim, standing in for picoruby-adc. The browser has no ADC, so the
 * class below returns a raw value JavaScript injects, and Board::Pad decodes it
 * with the same resistor-ladder table it uses on the board.
 *
 * Values are held per ADC channel, the way the hardware addresses them: RP2350
 * maps GPIO26..29 to channels 0..3, which is also what picoruby-adc reports as
 * @input. Which channels the pads sit on is board wiring, and that lives in
 * rootfs/lib/board/pad.rb. An unread channel reads 4095, pulled to 3V3. */
#define HARUCOM_ADC_CHANNELS 4
#define HARUCOM_ADC_FIRST_PIN 26
#define HARUCOM_ADC_MAX_RAW 4095
static uint16_t adc_raw[HARUCOM_ADC_CHANNELS] = {
  HARUCOM_ADC_MAX_RAW, HARUCOM_ADC_MAX_RAW, HARUCOM_ADC_MAX_RAW, HARUCOM_ADC_MAX_RAW
};

static int
adc_channel_for_pin(int pin)
{
  int channel = pin - HARUCOM_ADC_FIRST_PIN;
  return (channel >= 0 && channel < HARUCOM_ADC_CHANNELS) ? channel : -1;
}

/* Set what a pad reads. `pad` is the pad index the on-screen D-pads use, 0 or 1,
 * which map to the ADC channels Board::Pad reads. Out-of-range values are
 * rejected rather than truncated: a wrapped value would decode as a plausible
 * button instead of an obvious mistake. */
EMSCRIPTEN_KEEPALIVE
void
harucom_pad_set(int pad, int raw)
{
  int channel = adc_channel_for_pin(HARUCOM_PAD0_PIN + pad);
  if (channel < 0 || pad < 0 || pad > 1) return;
  if (raw < 0 || raw > HARUCOM_ADC_MAX_RAW) return;
  adc_raw[channel] = (uint16_t)raw;
}

static mrb_value
mrb_adc_initialize(mrb_state *mrb, mrb_value self)
{
  mrb_int pin;
  mrb_get_args(mrb, "i", &pin);
  if (adc_channel_for_pin((int)pin) < 0) {
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "Wrong ADC pin: %i", pin);
  }
  mrb_iv_set(mrb, self, MRB_IVSYM(input), mrb_fixnum_value(pin));
  return self;
}

static mrb_value
mrb_adc_read_raw(mrb_state *mrb, mrb_value self)
{
  mrb_value pin = mrb_iv_get(mrb, self, MRB_IVSYM(input));
  if (!mrb_integer_p(pin)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "ADC pin is not set");
  }
  int channel = adc_channel_for_pin((int)mrb_integer(pin));
  return mrb_fixnum_value(channel >= 0 ? adc_raw[channel] : HARUCOM_ADC_MAX_RAW);
}

/* Register the ADC pad shim, which is Board::Pad's only hardware dependency. */
void
mrb_harucom_os_wasm_gem_init(mrb_state *mrb)
{
  struct RClass *class_ADC = mrb_define_class_id(mrb, MRB_SYM(ADC), mrb->object_class);
  mrb_define_method_id(mrb, class_ADC, MRB_SYM(initialize), mrb_adc_initialize, MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, class_ADC, MRB_SYM(read_raw), mrb_adc_read_raw, MRB_ARGS_NONE());
}
