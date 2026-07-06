/*
 * picoruby-dmx/ports/rp2350/dmx_port.c
 *
 * DMX512 background transmit engine for RP2350.
 *
 * A repeating timer on a dedicated hardware alarm starts one frame every
 * 25 ms (40 Hz). Each frame runs a small alarm-driven state machine:
 *
 *   frame timer: assert BREAK with uart_set_break, wait 176 us
 *   phase alarm: release BREAK (MAB starts), wait 12 us
 *   phase alarm: kick DMA (start code + active slots to the UART TX FIFO)
 *
 * After the DMA kick the CPU is not involved; the UART TX DREQ paces the
 * transfer at 44 us per byte. Ruby never blocks on transmission.
 *
 * DMX timing tolerances are wide (BREAK >= 88 us, MAB >= 8 us, both may
 * stretch to almost 1 s), so jitter from higher-priority IRQs only
 * lengthens a phase, which receivers accept. The alarm pool is created
 * from dmx_init, which runs on Core 0, so the engine never interrupts
 * the DVI core.
 *
 * Dead-man switch: Ruby calls dmx_keepalive() from its main loop. While
 * the heartbeat is older than deadman_ms, the frame callback forces the
 * universe to zero before every frame, so a hung or crashed VM cannot
 * leave the rig lit (fixtures hold their last values on signal loss).
 * When the heartbeat resumes, values written by Ruby flow out again.
 */

#include <stdio.h>

#include "pico/stdlib.h"
#include "pico/time.h"
#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/uart.h"

#include "../../include/dmx.h"

#define DMX_UART     uart1
#define DMX_TXD_PIN  20
#define DMX_RXD_PIN  21
#define DMX_BAUDRATE 250000

/* TIMER0 alarms are all taken: 0 = mruby task tick (hal_task.c),
 * 1 = pwm-audio, 2 = PIO-USB SOF, 3 = SDK default alarm pool. DMX runs
 * its pool on TIMER1, which is otherwise unused. Alarm 1 is avoided
 * because pwm_audio_port.c raises the TIMER1_IRQ_1 priority. */
#define DMX_TIMER_NUM 1
#define DMX_HW_ALARM  0

#define DMX_BREAK_US 176
#define DMX_MAB_US   12

/* 40 Hz nominal. A full 512-slot frame takes about 22.8 ms, which fits
 * in the 25 ms period. If the previous frame is still draining at the
 * next tick, that frame is skipped and the period stretches to 30 Hz
 * until frames fit again. */
#define DMX_FRAME_INTERVAL_US    25000
#define DMX_DEGRADED_INTERVAL_US 33333

#define DMX_DEADMAN_DEFAULT_MS 500

static bool dmx_initialized = false;
static volatile bool dmx_running = false;
static int dma_channel = -1;
static alarm_pool_t *dmx_alarm_pool = NULL;
static repeating_timer_t frame_timer;

/* 0 = waiting for frame start, 1 = in BREAK, 2 = in MAB */
static volatile int frame_phase = 0;

static volatile uint32_t frame_counter = 0;
static volatile uint32_t skipped_frames = 0;

static volatile uint32_t deadman_ms = DMX_DEADMAN_DEFAULT_MS;
static volatile uint32_t last_keepalive_ms = 0;

/* BREAK and MAB share one one-shot alarm. A positive return value
 * reschedules from the time the callback exits, which guarantees the
 * minimum width of each phase. */
static int64_t
frame_phase_alarm(alarm_id_t id, void *user_data)
{
  (void)id;
  (void)user_data;
  if (!dmx_running) {
    /* Stopped mid-frame: release the line and abandon the frame. */
    uart_set_break(DMX_UART, false);
    frame_phase = 0;
    return 0;
  }
  if (frame_phase == 1) {
    uart_set_break(DMX_UART, false);
    frame_phase = 2;
    return DMX_MAB_US;
  }
  /* MAB done: hand the frame to the DMA channel. */
  frame_phase = 0;
  dma_channel_set_read_addr(dma_channel, (const void *)dmx_universe, false);
  dma_channel_set_trans_count(dma_channel, 1u + dmx_active_slots, true);
  frame_counter++;
  return 0;
}

static bool
frame_timer_callback(repeating_timer_t *timer)
{
  if (!dmx_running) return true;

  /* Frame guard: a new BREAK while the previous frame is still in the
   * DMA channel or the UART shifter would corrupt that frame's tail.
   * Skip this frame and retry at the degraded (30 Hz) period. */
  if (frame_phase != 0 || dma_channel_is_busy(dma_channel) ||
      (uart_get_hw(DMX_UART)->fr & UART_UARTFR_BUSY_BITS)) {
    skipped_frames++;
    timer->delay_us = -DMX_DEGRADED_INTERVAL_US;
    return true;
  }
  timer->delay_us = -DMX_FRAME_INTERVAL_US;

  /* Dead-man: without a recent heartbeat, force the rig dark. */
  if (deadman_ms > 0 &&
      to_ms_since_boot(get_absolute_time()) - last_keepalive_ms > deadman_ms) {
    dmx_blackout();
  }

  uart_set_break(DMX_UART, true);
  frame_phase = 1;
  if (alarm_pool_add_alarm_in_us(dmx_alarm_pool, DMX_BREAK_US, frame_phase_alarm, NULL,
                                 true) < 0) {
    /* Pool full (should not happen): do not leave the line in BREAK. */
    uart_set_break(DMX_UART, false);
    frame_phase = 0;
  }
  return true;
}

void
dmx_init(void)
{
  if (dmx_initialized) return;

  uart_init(DMX_UART, DMX_BAUDRATE);
  uart_set_format(DMX_UART, 8, 2, UART_PARITY_NONE);
  gpio_set_function(DMX_TXD_PIN, GPIO_FUNC_UART);
  gpio_set_function(DMX_RXD_PIN, GPIO_FUNC_UART);

  /* DVI holds channels 0/1 and PIO-USB claims channel 2, so this
   * normally lands on channel 3. */
  dma_channel = dma_claim_unused_channel(true);
  dma_channel_config config = dma_channel_get_default_config(dma_channel);
  channel_config_set_transfer_data_size(&config, DMA_SIZE_8);
  channel_config_set_read_increment(&config, true);
  channel_config_set_write_increment(&config, false);
  channel_config_set_dreq(&config, uart_get_dreq(DMX_UART, true));
  dma_channel_configure(dma_channel, &config, &uart_get_hw(DMX_UART)->dr,
                        (const void *)dmx_universe, 1u + DMX_SLOTS, false);

  /* Dedicated pool: the frame timer plus one in-flight phase alarm. */
  dmx_alarm_pool =
      alarm_pool_create_on_timer(alarm_pool_timer_for_timer_num(DMX_TIMER_NUM), DMX_HW_ALARM, 4);

  /* Start from a dark universe (fixtures may hold stale values). */
  dmx_blackout();
  dmx_initialized = true;

  printf("DMX: UART1 %d baud 8N2, TX=GPIO%d, DMA ch%d, TIMER%d alarm %d\n", DMX_BAUDRATE,
         DMX_TXD_PIN, dma_channel, DMX_TIMER_NUM, DMX_HW_ALARM);
}

void
dmx_start(void)
{
  if (!dmx_initialized || dmx_running) return;

  /* Start dark: the first frames overwrite whatever the fixtures
   * latched from a previous run. Set values after start. */
  dmx_blackout();
  last_keepalive_ms = to_ms_since_boot(get_absolute_time());
  frame_phase = 0;
  dmx_running = true;
  if (!alarm_pool_add_repeating_timer_us(dmx_alarm_pool, -DMX_FRAME_INTERVAL_US,
                                         frame_timer_callback, NULL, &frame_timer)) {
    dmx_running = false;
  }
}

void
dmx_stop(void)
{
  if (!dmx_running) return;
  dmx_running = false;
  cancel_repeating_timer(&frame_timer);
  /* A phase alarm still in flight sees dmx_running == false and
   * releases the line. Fixtures hold their last values, so send a
   * blackout and wait a few frames before stopping to go dark. */
}

uint32_t
dmx_frame_count(void)
{
  return frame_counter;
}

void
dmx_keepalive(void)
{
  last_keepalive_ms = to_ms_since_boot(get_absolute_time());
}

void
dmx_set_deadman_ms(uint32_t ms)
{
  /* Refresh the heartbeat so enabling the dead-man after a long idle
   * period does not trip it immediately. */
  last_keepalive_ms = to_ms_since_boot(get_absolute_time());
  deadman_ms = ms;
}
