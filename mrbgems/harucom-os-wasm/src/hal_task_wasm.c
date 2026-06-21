/*
 * WebAssembly HAL for mruby-task.
 *
 * Browser counterpart of src/hal_task.c. On the board the scheduler tick is
 * driven by a hardware timer interrupt; in the browser there are no interrupts
 * and the runtime is single threaded, so:
 *   - the tick is driven from JavaScript via mrb_tick() (see the wasm entry),
 *   - the interrupt enable/disable hooks are no-ops (nothing can preempt us),
 *   - idle and sleep must never block, or the browser event loop would freeze.
 */

#include <stdbool.h>
#include <stdint.h>

#include "picoruby.h"
#include "task_hal.h"

/* Defined in hal_machine_wasm.c */
void hal_stdin_init(void);

void
mrb_hal_task_init(mrb_state *mrb)
{
  (void)mrb;
  hal_stdin_init();
}

void
mrb_hal_task_final(mrb_state *mrb)
{
  (void)mrb;
}

/* Single-threaded: there is nothing to mask, so the critical-section hooks are
 * no-ops. */
void
mrb_task_enable_irq(void)
{
}

void
mrb_task_disable_irq(void)
{
}

/* The browser event loop provides idling between mrb_run_step() calls; spinning
 * here would freeze the page. */
void
mrb_hal_task_idle_cpu(mrb_state *mrb)
{
  (void)mrb;
}

void
mrb_hal_task_sleep_us(mrb_state *mrb, mrb_int usec)
{
  (void)mrb;
  (void)usec;
}

/* mrb_ro_data_p is provided as a macro by mruby/value.h (returns FALSE) when
 * MRB_USE_CUSTOM_RO_DATA_P is not defined, which is the case for this build, so
 * no implementation is needed here. */