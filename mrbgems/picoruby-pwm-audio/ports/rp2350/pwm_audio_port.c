/*
 * picoruby-pwm-audio/ports/rp2350/pwm_audio_port.c
 *
 * DMA-paced PWM output for RP2350. Runs entirely on Core 0 so DVI
 * (Core 1, DMA_IRQ_1) is not affected.
 *
 * A single DMA channel in endless mode (RP2350 TRANS_COUNT MODE=0xF)
 * reads pwm_audio_buf through a read ring wrap and writes CC-format
 * words straight into the PWM slice CC register, paced by the wrap
 * DREQ of a second, pin-less pacer slice that wraps once per sample
 * (5 carrier periods, see pwm_audio.h). Both slices count clk_sys and
 * are enabled in one register write with preset counters, so every CC
 * write lands mid carrier period and latches at the next carrier
 * wrap with a fixed phase; there is nothing to jitter or beat. One
 * channel with no re-arming also means no seams (a chained
 * two-channel ping-pong audibly hiccuped at each half).
 *
 * A low-rate render pump (repeating timer, ~10 ms) tracks the DMA
 * read pointer and renders fresh samples ahead of it via
 * pwm_audio_render_block(), so the engine is autonomous: Ruby only
 * changes tone parameters or schedules events, and a stalled VM
 * cannot underrun the output. The pump needs no timing precision;
 * its budget is the render lead (about two pump periods short of the
 * full buffer).
 *
 * The sample rate is clk_sys / (pacer wrap + 1) = 250 MHz / 5000 =
 * 50000 Hz exactly, which also removes the pitch error of the old
 * integer-microsecond repeating timer.
 */

#include "pico/stdlib.h"
#include "pico/time.h"
#include <stdio.h>

#include "hardware/pwm.h"
#include "hardware/irq.h"
#include "hardware/dma.h"
#include "hardware/clocks.h"
#include "hardware/sync.h"

#include "../../include/pwm_audio.h"

/* TIMER1 alarm 1: alarm 0 is the DMX frame pool (dmx_port.c), TIMER0
 * alarms belong to the task tick, PIO-USB SOF, and the SDK pool. */
#define AUDIO_TIMER_NUM 1
#define AUDIO_HW_ALARM  1

#define AUDIO_PUMP_INTERVAL_US 10000
/* Keep the renderer this many samples clear of the DMA read pointer
 * so an in-progress ring fetch never sees a half-written word. */
#define AUDIO_RENDER_GUARD 16

/* Pacer slice: wraps once per sample and paces the DMA. Slices 8-11
 * have no GPIO pins on the RP2350A package, so slice 8 cannot collide
 * with any pin function. */
#define AUDIO_PACER_SLICE 8
#define AUDIO_PACER_WRAP \
  ((PWM_AUDIO_CARRIER_HZ / PWM_AUDIO_SAMPLE_RATE) * (PWM_AUDIO_PWM_WRAP + 1) - 1)

static uint slice_num;
static uint chan_l;
static uint chan_r;

static int dma_chan = -1;
static alarm_pool_t *audio_alarm_pool = NULL;
static repeating_timer_t pump_timer;
static bool audio_running = false;

/* Playback bookkeeping, updated under pwm_audio_lock(). played_total
 * accumulates ring-wrap deltas of the DMA read pointer; consumed_mod
 * is the pointer's last seen word offset. render_position is where
 * rendering continues on the sample timeline. The pump runs well
 * inside one buffer duration (~46 ms), so wrap deltas are unambiguous. */
static uint64_t played_total;
static uint32_t consumed_mod;
static uint64_t render_position;

/* Render health counters (see pwm_audio_stats). */
static int32_t stat_min_lead = PWM_AUDIO_BUF_SIZE;
static uint32_t stat_max_gap_us;
static uint64_t last_pump_us;

/* Pacing drift: consumed samples minus wall-clock expectation. A DMA
 * or pacing stall that loses output time shows up as a step toward
 * negative that never recovers. */
static uint64_t start_us;
static int32_t stat_drift_now;
static int32_t stat_drift_min;

uint32_t
pwm_audio_lock(void)
{
  return save_and_disable_interrupts();
}

void
pwm_audio_unlock(uint32_t state)
{
  restore_interrupts(state);
}

/* Fold the DMA read pointer into played_total. Call with the lock
 * held (or from the pump IRQ). */
static uint64_t
accumulate_played(void)
{
  uint32_t addr = dma_channel_hw_addr(dma_chan)->read_addr;
  uint32_t mod = ((addr - (uint32_t)(uintptr_t)pwm_audio_buf) >> 2) & PWM_AUDIO_BUF_MASK;
  played_total += (mod - consumed_mod) & PWM_AUDIO_BUF_MASK;
  consumed_mod = mod;
  return played_total;
}

void
pwm_audio_stats(int32_t *min_lead, uint32_t *max_gap_us, int32_t *drift_now,
                int32_t *drift_min)
{
  uint32_t state = save_and_disable_interrupts();
  *min_lead = stat_min_lead;
  *max_gap_us = stat_max_gap_us;
  *drift_now = stat_drift_now;
  *drift_min = stat_drift_min;
  restore_interrupts(state);
}

uint64_t
pwm_audio_sample_clock(void)
{
  if (!audio_running) return 0;
  uint32_t state = save_and_disable_interrupts();
  uint64_t clock = accumulate_played();
  restore_interrupts(state);
  return clock;
}

/* Render fresh samples ahead of the DMA reader, in ring-contiguous
 * spans. Runs in the alarm IRQ; also called once at init. */
static void
pump_render(void)
{
  uint64_t now_us = time_us_64();
  if (last_pump_us != 0) {
    uint32_t gap = (uint32_t)(now_us - last_pump_us);
    if (gap > stat_max_gap_us) stat_max_gap_us = gap;
  }
  last_pump_us = now_us;

  uint64_t played = accumulate_played();
  int32_t lead = (int32_t)(int64_t)(render_position - played);
  if (lead < stat_min_lead) stat_min_lead = lead;

  uint64_t expected = (now_us - start_us) * PWM_AUDIO_SAMPLE_RATE / 1000000u;
  stat_drift_now = (int32_t)(int64_t)(played - expected);
  if (stat_drift_now < stat_drift_min) stat_drift_min = stat_drift_now;

  uint64_t limit = played + PWM_AUDIO_BUF_SIZE - AUDIO_RENDER_GUARD;
  while (render_position < limit) {
    uint32_t offset = (uint32_t)(render_position & PWM_AUDIO_BUF_MASK);
    uint32_t span = PWM_AUDIO_BUF_SIZE - offset;
    uint64_t needed = limit - render_position;
    if ((uint64_t)span > needed) span = (uint32_t)needed;
    pwm_audio_render_block(render_position, &pwm_audio_buf[offset], span);
    render_position += span;
  }
}

static bool
pump_callback(repeating_timer_t *t)
{
  (void)t;
  pump_render();
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
  pwm_audio_l_is_pwm_a = (chan_l == PWM_CHAN_A);

  /* The wrap constants assume the project clock; a mismatch shifts
   * every pitch, so make it loud. */
  uint32_t clk = clock_get_hz(clk_sys);
  if (clk != (uint32_t)(AUDIO_PACER_WRAP + 1) * PWM_AUDIO_SAMPLE_RATE) {
    printf("pwm_audio: clk_sys %lu != pacer wrap+1 (%d) * rate (%d); pitches will be off\n",
           (unsigned long)clk, AUDIO_PACER_WRAP + 1, PWM_AUDIO_SAMPLE_RATE);
  }

  /* Configure both slices disabled; they are enabled together below
   * so their phase relation is exact. */
  pwm_set_enabled(slice_num, false);
  pwm_set_enabled(AUDIO_PACER_SLICE, false);
  pwm_set_wrap(slice_num, PWM_AUDIO_PWM_WRAP);
  pwm_set_clkdiv_int_frac(slice_num, 1, 0);
  pwm_set_both_levels(slice_num, 0, 0);
  pwm_set_counter(slice_num, 0);
  pwm_set_wrap(AUDIO_PACER_SLICE, AUDIO_PACER_WRAP);
  pwm_set_clkdiv_int_frac(AUDIO_PACER_SLICE, 1, 0);
  /* Preset the pacer so its wrap (the DMA trigger) always lands when
   * the carrier counter is mid period: the first wrap comes after
   * (pacer wrap+1 - preset) = half a carrier period, and every later
   * wrap advances the carrier counter by an exact whole number of
   * periods. */
  pwm_set_counter(AUDIO_PACER_SLICE,
                  AUDIO_PACER_WRAP + 1 - (PWM_AUDIO_PWM_WRAP + 1) / 2);

  pwm_audio_stop_all();

  /* Set default pan to center for all channels */
  for (int i = 0; i < PWM_AUDIO_NUM_CHANNELS; i++) {
    pwm_audio_set_pan(i, 8);
  }

  dma_chan = dma_claim_unused_channel(true);
  dma_channel_config config = dma_channel_get_default_config(dma_chan);
  channel_config_set_transfer_data_size(&config, DMA_SIZE_32);
  channel_config_set_read_increment(&config, true);
  channel_config_set_write_increment(&config, false);
  channel_config_set_dreq(&config, pwm_get_dreq(AUDIO_PACER_SLICE));
  channel_config_set_ring(&config, false, PWM_AUDIO_BUF_BITS + 2); /* wrap read on the buffer bytes */
  dma_channel_configure(dma_chan, &config, &pwm_hw->slice[slice_num].cc, pwm_audio_buf,
                        PWM_AUDIO_BUF_SIZE, false);
  /* Endless mode: TRANS_COUNT never decrements, the channel streams
   * the ring forever with no re-arm seam. */
  dma_channel_hw_addr(dma_chan)->transfer_count =
      (DMA_CH0_TRANS_COUNT_MODE_VALUE_ENDLESS << DMA_CH0_TRANS_COUNT_MODE_LSB) | 1u;

  /* Prefill the whole ring (silence) before starting. */
  played_total = 0;
  consumed_mod = 0;
  render_position = 0;
  stat_min_lead = PWM_AUDIO_BUF_SIZE;
  stat_max_gap_us = 0;
  last_pump_us = 0;
  stat_drift_now = 0;
  stat_drift_min = 0;
  start_us = time_us_64();
  pwm_audio_render_block(0, pwm_audio_buf, PWM_AUDIO_BUF_SIZE);
  render_position = PWM_AUDIO_BUF_SIZE;

  dma_channel_start(dma_chan);

  /* Enable both slices in one write so the preset counter phase
   * between them holds from the first cycle. */
  hw_set_bits(&pwm_hw->en, (1u << slice_num) | (1u << AUDIO_PACER_SLICE));

  if (!audio_alarm_pool) {
    audio_alarm_pool = alarm_pool_create_on_timer(
        alarm_pool_timer_for_timer_num(AUDIO_TIMER_NUM), AUDIO_HW_ALARM, 2);
  }
  if (!alarm_pool_add_repeating_timer_us(audio_alarm_pool, -AUDIO_PUMP_INTERVAL_US,
                                         pump_callback, NULL, &pump_timer)) {
    return;
  }

  audio_running = true;
}

void
pwm_audio_deinit(void)
{
  if (!audio_running) return;

  cancel_repeating_timer(&pump_timer);
  if (audio_alarm_pool) {
    alarm_pool_destroy(audio_alarm_pool);
    audio_alarm_pool = NULL;
  }

  /* RP2350-E5: clear the channel enable before aborting so the abort
   * cannot retrigger. */
  hw_clear_bits(&dma_channel_hw_addr(dma_chan)->al1_ctrl, DMA_CH0_CTRL_TRIG_EN_BITS);
  dma_channel_abort(dma_chan);
  dma_channel_unclaim(dma_chan);
  dma_chan = -1;

  pwm_audio_stop_all();
  pwm_set_both_levels(slice_num, 0, 0);
  pwm_set_enabled(slice_num, false);
  pwm_set_enabled(AUDIO_PACER_SLICE, false);

  audio_running = false;
}
