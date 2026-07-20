#include <mruby.h>
#include <mruby/presym.h>

#include "boards/harucom_board.h"

/*
 * The Grove connector shares its two signal pins with I2C0 and UART1:
 *   GPIO 20 = I2C SDA = UART TX
 *   GPIO 21 = I2C SCL = UART RX
 * so the I2C_*, GROVE_*, and GROVE_UART_* names alias the same pins.
 */

void
mrb_picoruby_harucom_board_gem_init(mrb_state *mrb)
{
  struct RClass *module_Board = mrb_define_module_id(mrb, MRB_SYM(Board));

  /* LEDs */
  mrb_define_const_id(mrb, module_Board, MRB_SYM(LED_GREEN_PIN), mrb_fixnum_value(PICO_DEFAULT_LED_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(LED_RED_PIN),   mrb_fixnum_value(HARUCOM_LED_RED_PIN));

  /* ADC resistor ladder pads */
  mrb_define_const_id(mrb, module_Board, MRB_SYM(PAD0_PIN), mrb_fixnum_value(HARUCOM_BUTTONS_0_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(PAD1_PIN), mrb_fixnum_value(HARUCOM_BUTTONS_1_PIN));

  /* PWM audio */
  mrb_define_const_id(mrb, module_Board, MRB_SYM(AUDIO_L_PIN), mrb_fixnum_value(HARUCOM_AUDIO_L_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(AUDIO_R_PIN), mrb_fixnum_value(HARUCOM_AUDIO_R_PIN));

  /* UART0 (default console UART) */
  mrb_define_const_id(mrb, module_Board, MRB_SYM(UART_TX_PIN), mrb_fixnum_value(PICO_DEFAULT_UART_TX_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(UART_RX_PIN), mrb_fixnum_value(PICO_DEFAULT_UART_RX_PIN));

  /* SPI0 */
  mrb_define_const_id(mrb, module_Board, MRB_SYM(SPI_SCK_PIN), mrb_fixnum_value(PICO_DEFAULT_SPI_SCK_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(SPI_TX_PIN),  mrb_fixnum_value(PICO_DEFAULT_SPI_TX_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(SPI_RX_PIN),  mrb_fixnum_value(PICO_DEFAULT_SPI_RX_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(SPI_CSN_PIN), mrb_fixnum_value(PICO_DEFAULT_SPI_CSN_PIN));

  /* I2C0 (routed to the Grove connector) */
  mrb_define_const_id(mrb, module_Board, MRB_SYM(I2C_SDA_PIN), mrb_fixnum_value(PICO_DEFAULT_I2C_SDA_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(I2C_SCL_PIN), mrb_fixnum_value(PICO_DEFAULT_I2C_SCL_PIN));

  /* Grove connector names for the same two pins */
  mrb_define_const_id(mrb, module_Board, MRB_SYM(GROVE_SDA_PIN),     mrb_fixnum_value(PICO_DEFAULT_I2C_SDA_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(GROVE_SCL_PIN),     mrb_fixnum_value(PICO_DEFAULT_I2C_SCL_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(GROVE_UART_TX_PIN), mrb_fixnum_value(PICO_DEFAULT_I2C_SDA_PIN));
  mrb_define_const_id(mrb, module_Board, MRB_SYM(GROVE_UART_RX_PIN), mrb_fixnum_value(PICO_DEFAULT_I2C_SCL_PIN));
}

void
mrb_picoruby_harucom_board_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
