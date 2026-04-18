/*
 * HAL (Hardware Abstraction Layer) for mruby-task
 *
 * Implements the custom HAL for the mruby-task scheduler on RP2350.
 * Provides timer initialization, interrupt enable/disable, and idle CPU.
 *
 * See lib/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/README.md
 */

#include <stdbool.h>
#include <stdint.h>

#include "hardware/sync.h"
#include "hardware/timer.h"
#include "pico/stdlib.h"

#include "picoruby.h"
#include "task_hal.h"

/* Defined in hal_machine.c */
void hal_stdin_init(void);

/*-------------------------------------
 *
 * Timer initialization and tick handler
 *
 *------------------------------------*/

#define ALARM_NUM 0
#define ALARM_IRQ timer_hardware_alarm_get_irq_num(timer_hw, ALARM_NUM)

#ifndef MRB_TICK_UNIT
#define MRB_TICK_UNIT 1
#endif
#define US_PER_MS (MRB_TICK_UNIT * 1000)

static volatile uint32_t interrupt_nesting = 0;
static volatile bool in_tick_processing = false;
static mrb_state *mrb_;

static void
alarm_handler(void)
{
  if (in_tick_processing) {
    timer_hw->alarm[ALARM_NUM] = timer_hw->timerawl + US_PER_MS;
    hw_clear_bits(&timer_hw->intr, 1u << ALARM_NUM);
    return;
  }

  in_tick_processing = true;
  __dmb();

  uint32_t current_time = timer_hw->timerawl;
  uint32_t next_time = current_time + US_PER_MS;
  timer_hw->alarm[ALARM_NUM] = next_time;
  hw_clear_bits(&timer_hw->intr, 1u << ALARM_NUM);

  mrb_tick(mrb_);

  __dmb();
  in_tick_processing = false;
}

void
mrb_hal_task_init(mrb_state *mrb)
{
  mrb_ = mrb;
  hal_stdin_init();
  hw_set_bits(&timer_hw->inte, 1u << ALARM_NUM);
  irq_set_exclusive_handler(ALARM_IRQ, alarm_handler);
  irq_set_enabled(ALARM_IRQ, true);
  /* Priority 0x20: below PIO-USB SOF timer (0x00) so that USB transactions
   * are not preempted by the mruby task scheduler tick. */
  irq_set_priority(ALARM_IRQ, 0x20);
  timer_hw->alarm[ALARM_NUM] = timer_hw->timerawl + US_PER_MS;
}

void
mrb_hal_task_final(mrb_state *mrb)
{
  (void)mrb;
}

/*-------------------------------------
 *
 * Enable/disable timer interrupts (reentrant)
 *
 *------------------------------------*/

void
mrb_task_enable_irq(void)
{
  if (interrupt_nesting == 0) {
    return;
  }
  interrupt_nesting--;
  if (interrupt_nesting > 0) {
    return;
  }
  __dmb();
  asm volatile("cpsie i" : : : "memory");
}

void
mrb_task_disable_irq(void)
{
  asm volatile("cpsid i" : : : "memory");
  __dmb();
  interrupt_nesting++;
}

/*-------------------------------------
 *
 * Idle CPU (low-power mode)
 *
 *------------------------------------*/

void
mrb_hal_task_idle_cpu(mrb_state *mrb)
{
  (void)mrb;
  asm volatile("wfe\n"
               "nop\n"
               "sev\n"
               :
               :
               : "memory");
}

void
mrb_hal_task_sleep_us(mrb_state *mrb, mrb_int usec)
{
  (void)mrb;
  sleep_us((uint32_t)usec);
}

/*-------------------------------------
 *
 * Read-only data check (for MRB_USE_CUSTOM_RO_DATA_P)
 *
 *------------------------------------*/

extern char __etext;

bool
mrb_ro_data_p(const char *p)
{
  return p < &__etext;
}
