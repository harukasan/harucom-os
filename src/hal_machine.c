/*
 * HAL for picoruby-machine
 *
 * Implements the hal.h I/O interface and the Machine_* hardware control
 * functions on RP2350.
 *
 * See lib/picoruby/mrbgems/picoruby-machine/README.md
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

#include "hardware/timer.h"
#include "hardware/watchdog.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"
#include "pico/unique_id.h"
#include "pico/aon_timer.h"

#include "machine.h"
#include "ringbuffer.h"
#include "io-console.h"

/* Forward declarations */
int hal_write(int fd, const void *buf, int nbytes);

/* ===================================================================
 * HAL I/O (hal.h)
 * =================================================================== */

/*-------------------------------------
 *
 * Signal flag
 *
 *------------------------------------*/

volatile int sigint_status = MACHINE_SIG_NONE;

/*-------------------------------------
 *
 * stdin RingBuffer
 *
 *------------------------------------*/

#ifndef PICORB_STDIN_BUFFER_SIZE
#define PICORB_STDIN_BUFFER_SIZE 256
#endif

static uint8_t stdin_buf_mem[sizeof(RingBuffer) + PICORB_STDIN_BUFFER_SIZE]
    __attribute__((aligned(4)));
static RingBuffer *stdin_rb = (RingBuffer *)stdin_buf_mem;

void
hal_stdin_init(void)
{
  RingBuffer_init(stdin_rb, PICORB_STDIN_BUFFER_SIZE);
}

void
hal_stdin_push(uint8_t ch)
{
  if (!io_raw_q()) {
    if (ch == 3) {
      sigint_status = MACHINE_SIGINT_RECEIVED;
      return;
    }
    if (ch == 26) {
      sigint_status = MACHINE_SIGTSTP_RECEIVED;
      return;
    }
  }
  RingBuffer_push(stdin_rb, ch);
}

/*-------------------------------------
 *
 * Canonical (cooked mode) line buffer
 *
 *------------------------------------*/

#ifndef PICORB_CANONICAL_BUF_SIZE
#define PICORB_CANONICAL_BUF_SIZE 256
#endif

static uint8_t canon_buf[PICORB_CANONICAL_BUF_SIZE];
static int canon_len = 0;
static int canon_read_pos = 0;
static bool canon_eof = false;

#define CANON_LINE_READY   1
#define CANON_EOF          2
#define CANON_ACCUMULATING 0

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
    if (canon_len < PICORB_CANONICAL_BUF_SIZE) {
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
  if (canon_len < PICORB_CANONICAL_BUF_SIZE) {
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

#define HAL_GETCHAR_NODATA (-1)
#define HAL_GETCHAR_EOF    (-2)

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

int
hal_getchar(void)
{
  poll_stdio_to_ringbuffer();

  if (sigint_status == MACHINE_SIGINT_RECEIVED) {
    sigint_status = MACHINE_SIG_NONE;
    return 3;
  }
  if (sigint_status == MACHINE_SIGTSTP_RECEIVED) {
    sigint_status = MACHINE_SIG_NONE;
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
  if (RingBuffer_search_char(stdin_rb, '\n') >= 0 || RingBuffer_search_char(stdin_rb, '\r') >= 0 ||
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

/* ===================================================================
 * Machine_* functions (machine.h)
 * =================================================================== */

/*-------------------------------------
 *
 * USB Device (stubs)
 *
 *------------------------------------*/

void
Machine_tud_task(void)
{
}

bool
Machine_tud_mounted_q(void)
{
  return false;
}

/*-------------------------------------
 *
 * Timing
 *
 *------------------------------------*/

void
Machine_delay_ms(uint32_t ms)
{
  sleep_ms(ms);
}

void
Machine_busy_wait_ms(uint32_t ms)
{
  busy_wait_us_32(1000 * ms);
}

void
Machine_busy_wait_us(uint32_t us)
{
  busy_wait_us_32(us);
}

uint64_t
Machine_uptime_us(void)
{
  return time_us_64();
}

void
Machine_uptime_formatted(char *buf, int maxlen)
{
  uint64_t us = Machine_uptime_us();
  uint32_t sec = us / 1000000;
  uint32_t min = sec / 60;
  uint32_t hour = min / 60;
  uint32_t day = hour / 24;
  snprintf(buf, maxlen, "%ud %02u:%02u:%02u.%02u", (unsigned)day, (unsigned)(hour % 24),
           (unsigned)(min % 60), (unsigned)(sec % 60), (unsigned)((us % 1000000) / 10000));
}

/*-------------------------------------
 *
 * System
 *
 *------------------------------------*/

bool
Machine_get_unique_id(char *id_str)
{
  pico_get_unique_board_id_string(id_str, PICO_UNIQUE_BOARD_ID_SIZE_BYTES * 2 + 1);
  return true;
}

uint32_t
Machine_stack_usage(void)
{
  return 0;
}

void
Machine_exit(int status)
{
  (void)status;
}

void
Machine_reboot(void)
{
  watchdog_reboot(0, 0, 0);
}

/*-------------------------------------
 *
 * Sleep
 *
 *------------------------------------*/

void
Machine_sleep(uint32_t seconds)
{
  sleep_ms(seconds * 1000);
}

void
Machine_deep_sleep(uint8_t gpio_pin, bool edge, bool high)
{
  (void)gpio_pin;
  (void)edge;
  (void)high;
}

/*-------------------------------------
 *
 * Hardware clock (AON timer)
 *
 *------------------------------------*/

bool
Machine_set_hwclock(const struct timespec *ts)
{
  if (aon_timer_is_running()) {
    return aon_timer_set_time(ts);
  }
  return aon_timer_start(ts);
}

bool
Machine_get_hwclock(struct timespec *ts)
{
  return aon_timer_get_time(ts);
}
