/*
 * picoruby-pwm-audio/ports/rp2350/pwm_audio_port.c
 *
 * PWM output and timer ISR for RP2350.
 * Runs entirely on Core 0 so DVI (Core 1) is not affected.
 *
 * The ISR reads pre-rendered samples from a ring buffer and writes
 * to PWM. The buffer is filled by pwm_audio_fill_buffer(), which
 * must be called from the Ruby main loop via PWMAudio.update.
 */

#include "pico/stdlib.h"
#include "pico/time.h"
#include "hardware/pwm.h"
#include "hardware/irq.h"

#include "../../include/pwm_audio.h"

#define AUDIO_HW_ALARM  1
#define AUDIO_IRQ       TIMER1_IRQ_1

static uint slice_num;
static uint chan_l;
static uint chan_r;

static alarm_pool_t *audio_alarm_pool = NULL;
static repeating_timer_t audio_timer;
static bool audio_running = false;

static bool
audio_isr(repeating_timer_t *t)
{
  (void)t;
  if (pwm_audio_rd == pwm_audio_wr) return true;  /* buffer empty */
  uint32_t sample = pwm_audio_buf[pwm_audio_rd & PWM_AUDIO_BUF_MASK];
  pwm_audio_rd++;
  uint16_t l = sample >> 16;
  uint16_t r = sample & 0xFFFF;
  if (chan_l == PWM_CHAN_A) {
    pwm_set_both_levels(slice_num, l, r);
  } else {
    pwm_set_both_levels(slice_num, r, l);
  }
  return true;
}

void
pwm_audio_init(uint8_t l_pin, uint8_t r_pin)
{
  if (audio_running) return;

  gpio_set_function(l_pin, GPIO_FUNC_PWM);
  gpio_set_function(r_pin, GPIO_FUNC_PWM);

  slice_num = pwm_gpio_to_slice_num(l_pin);
  chan_l = pwm_gpio_to_channel(l_pin);
  chan_r = pwm_gpio_to_channel(r_pin);

  pwm_set_wrap(slice_num, PWM_AUDIO_PWM_WRAP);
  pwm_set_clkdiv_int_frac(slice_num, 1, 0);
  pwm_set_both_levels(slice_num, 0, 0);
  pwm_set_enabled(slice_num, true);

  pwm_audio_stop_all();

  /* Set default pan to center for all channels */
  for (int i = 0; i < PWM_AUDIO_NUM_CHANNELS; i++) {
    pwm_audio_set_pan(i, 8);
  }

  /* Pre-fill the buffer before starting the timer */
  pwm_audio_rd = 0;
  pwm_audio_wr = 0;
  pwm_audio_fill_buffer();

  if (!audio_alarm_pool) {
    audio_alarm_pool = alarm_pool_create(AUDIO_HW_ALARM, 2);
    irq_set_priority(AUDIO_IRQ, 0);  /* highest priority */
  }
  if (!alarm_pool_add_repeating_timer_us(
        audio_alarm_pool,
        -(1000000 / PWM_AUDIO_SAMPLE_RATE),
        audio_isr, NULL, &audio_timer)) {
    return;
  }

  audio_running = true;
}

void
pwm_audio_deinit(void)
{
  if (!audio_running) return;

  cancel_repeating_timer(&audio_timer);
  if (audio_alarm_pool) {
    alarm_pool_destroy(audio_alarm_pool);
    audio_alarm_pool = NULL;
  }

  pwm_audio_stop_all();
  pwm_set_both_levels(slice_num, 0, 0);
  pwm_set_enabled(slice_num, false);

  audio_running = false;
}
