/*
 * Minimal HAL implementation for PicoRuby on RP2350
 *
 * Provides:
 *   - Task HAL (timer tick, IRQ control, idle, sleep)
 *   - I/O HAL (write, read stubs)
 *   - io-console stubs
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>

#include "hardware/timer.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"

#include "picoruby.h"
#include "task_hal.h"
#include "ringbuffer.h"

/* Forward declarations */
int hal_write(int fd, const void *buf, int nbytes);
void hal_stdin_push(uint8_t ch);
bool io_raw_q(void);
bool io_echo_q(void);

/*-------------------------------------
 *
 * Task HAL — Timer tick for mruby-task scheduler
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

/*-------------------------------------
 *
 * stdin RingBuffer (following picoruby-machine pattern)
 *
 *------------------------------------*/

#ifndef PICORUBY_STDIN_BUFFER_SIZE
#define PICORUBY_STDIN_BUFFER_SIZE 256
#endif

static uint8_t stdin_buf_mem[sizeof(RingBuffer) + PICORUBY_STDIN_BUFFER_SIZE]
  __attribute__((aligned(4)));
static RingBuffer *stdin_rb = (RingBuffer *)stdin_buf_mem;

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
  RingBuffer_init(stdin_rb, PICORUBY_STDIN_BUFFER_SIZE);
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
  asm volatile ("cpsie i" : : : "memory");
}

void
mrb_task_disable_irq(void)
{
  asm volatile ("cpsid i" : : : "memory");
  __dmb();
  interrupt_nesting++;
}

void
mrb_hal_task_idle_cpu(mrb_state *mrb)
{
  (void)mrb;
  asm volatile (
    "wfe\n"
    "nop\n"
    "sev\n"
    : : : "memory"
  );
}

void
mrb_hal_task_sleep_us(mrb_state *mrb, mrb_int usec)
{
  (void)mrb;
  sleep_us((uint32_t)usec);
}

/*-------------------------------------
 *
 * Signal flag
 *
 *------------------------------------*/

#define SIG_NONE            0
#define SIGINT_RECEIVED     1
#define SIGTSTP_RECEIVED    2

volatile int sigint_status = SIG_NONE;

/*-------------------------------------
 *
 * io-console stubs
 *
 *------------------------------------*/

bool
io_raw_q(void)
{
  return false;
}

bool
io_echo_q(void)
{
  return false;
}

/*-------------------------------------
 *
 * Canonical (cooked mode) line buffer
 *
 *------------------------------------*/

#ifndef PICORUBY_CANONICAL_BUF_SIZE
#define PICORUBY_CANONICAL_BUF_SIZE 256
#endif

static uint8_t canon_buf[PICORUBY_CANONICAL_BUF_SIZE];
static int canon_len = 0;
static int canon_read_pos = 0;
static bool canon_eof = false;

#define CANON_LINE_READY    1
#define CANON_EOF           2
#define CANON_ACCUMULATING  0

static int
canon_process_char(uint8_t raw)
{
  if (raw == 8 || raw == 127) {
    if (canon_len > 0) {
      canon_len--;
      if (io_echo_q()) {
        hal_write(1, "\b \b", 3);
      }
    }
    return CANON_ACCUMULATING;
  }
  if (raw == '\n' || raw == '\r') {
    if (canon_len < PICORUBY_CANONICAL_BUF_SIZE) {
      canon_buf[canon_len++] = raw;
    }
    if (io_echo_q()) {
      hal_write(1, "\r\n", 2);
    }
    canon_read_pos = 0;
    return CANON_LINE_READY;
  }
  if (raw == 4) {
    if (canon_len == 0) {
      canon_eof = true;
      return CANON_EOF;
    }
    canon_read_pos = 0;
    return CANON_LINE_READY;
  }
  if (raw == 27) {
    return CANON_ACCUMULATING;
  }
  if (canon_len < PICORUBY_CANONICAL_BUF_SIZE) {
    canon_buf[canon_len++] = raw;
    if (io_echo_q()) {
      hal_write(1, &raw, 1);
    }
  }
  return CANON_ACCUMULATING;
}

/*-------------------------------------
 *
 * I/O HAL
 *
 *------------------------------------*/

#define HAL_GETCHAR_NODATA  (-1)
#define HAL_GETCHAR_EOF     (-2)

static void
poll_stdio_to_ringbuffer(void)
{
  int c = getchar_timeout_us(0);
  if (c >= 0) {
    hal_stdin_push((uint8_t)c);
  }
}

int
hal_write(int fd, const void *buf, int nbytes)
{
  (void)fd;
  const char *p = (const char *)buf;
  for (int i = 0; i < nbytes; i++) {
    putchar(p[i]);
  }
  return nbytes;
}

int
hal_flush(int fd)
{
  (void)fd;
  stdio_flush();
  return 0;
}

void
hal_stdin_push(uint8_t ch)
{
  if (!io_raw_q()) {
    if (ch == 3) {
      sigint_status = SIGINT_RECEIVED;
      return;
    }
    if (ch == 26) {
      sigint_status = SIGTSTP_RECEIVED;
      return;
    }
  }
  RingBuffer_push(stdin_rb, ch);
}

int
hal_getchar(void)
{
  poll_stdio_to_ringbuffer();

  if (sigint_status == SIGINT_RECEIVED) {
    sigint_status = SIG_NONE;
    return 3;
  }
  if (sigint_status == SIGTSTP_RECEIVED) {
    sigint_status = SIG_NONE;
    return 26;
  }

  if (io_raw_q()) {
    uint8_t ch;
    if (RingBuffer_pop(stdin_rb, &ch)) {
      return (int)ch;
    }
    return HAL_GETCHAR_NODATA;
  }

  if (canon_read_pos < canon_len) {
    uint8_t ch = canon_buf[canon_read_pos++];
    if (canon_read_pos >= canon_len) {
      canon_len = 0;
      canon_read_pos = 0;
    }
    return (int)ch;
  }

  if (canon_eof) {
    canon_eof = false;
    return HAL_GETCHAR_EOF;
  }

  uint8_t raw;
  if (!RingBuffer_pop(stdin_rb, &raw)) {
    return HAL_GETCHAR_NODATA;
  }

  int result = canon_process_char(raw);
  switch (result) {
    case CANON_LINE_READY:
      return hal_getchar();
    case CANON_EOF:
      canon_eof = false;
      return HAL_GETCHAR_EOF;
    default:
      return HAL_GETCHAR_NODATA;
  }
}

int
hal_read_available(void)
{
  poll_stdio_to_ringbuffer();

  if (io_raw_q()) {
    return (RingBuffer_data_size(stdin_rb) > 0) ? 1 : 0;
  }
  if (canon_read_pos < canon_len) {
    return 1;
  }
  if (RingBuffer_search_char(stdin_rb, '\n') >= 0 ||
      RingBuffer_search_char(stdin_rb, '\r') >= 0 ||
      RingBuffer_search_char(stdin_rb, 4) >= 0) {
    return 1;
  }
  return 0;
}

void
hal_abort(const char *s)
{
  if (s) {
    printf("%s\n", s);
  }
  while (1) {
    __breakpoint();
  }
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
