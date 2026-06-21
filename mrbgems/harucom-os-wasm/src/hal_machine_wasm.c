/*
 * WebAssembly HAL for picoruby-machine.
 *
 * Browser counterpart of src/hal_machine.c. Implements the hal.h I/O interface
 * and the Machine_* control functions on emscripten. The cooked-mode line
 * machinery (RingBuffer, canonical buffer, hal_getchar) is kept verbatim from
 * the board HAL; only the endpoints change:
 *   - stdin is fed by JavaScript via hal_stdin_push() (keyboard / debug input),
 *     so there is no UART polling.
 *   - hal_write() forwards bytes to a JavaScript sink (console / DOM).
 *   - timing comes from emscripten_get_now() instead of the RP2350 timer.
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include <emscripten.h>

#include "machine.h"
#include "ringbuffer.h"
#include "io-console.h"

/* Forward declaration (defined below). */
int hal_write(int fd, const void *buf, int nbytes);

/* ===================================================================
 * HAL I/O (hal.h)
 * =================================================================== */

/* Signal flag. On non-posix platforms machine.h only declares this extern, so
 * the platform HAL must define it (as the board does in src/hal_machine.c). */
volatile int sigint_status = MACHINE_SIG_NONE;

/*-------------------------------------
 * stdin RingBuffer
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

/* Called from JavaScript to feed a byte into stdin (keyboard / debug). */
EMSCRIPTEN_KEEPALIVE
void
harucom_stdin_push(int ch)
{
  hal_stdin_push((uint8_t)ch);
}

/*-------------------------------------
 * Canonical (cooked mode) line buffer
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
 * I/O HAL
 *------------------------------------*/

#define HAL_GETCHAR_NODATA (-1)
#define HAL_GETCHAR_EOF    (-2)

/* No UART on wasm: stdin arrives through hal_stdin_push() from JavaScript. */
static void
poll_stdio_to_ringbuffer(void)
{
}

/* Forward bytes to a JavaScript sink. Module.harucomStdout(str), if defined by
 * the page, receives each write; otherwise it falls back to console.log. The
 * per-byte decode is ASCII-only for now (UTF-8 handling lands with the canvas
 * console in a later phase). */
EM_JS(void, harucom_js_stdout, (const char *p, int n), {
  var s = "";
  for (var i = 0; i < n; i++) {
    s += String.fromCharCode(HEAPU8[p + i]);
  }
  if (typeof Module !== "undefined" && Module.harucomStdout) {
    Module.harucomStdout(s);
  } else {
    console.log(s);
  }
});

int
hal_write(int fd, const void *buf, int nbytes)
{
  (void)fd;
  harucom_js_stdout((const char *)buf, nbytes);
  return nbytes;
}

int
hal_flush(int fd)
{
  (void)fd;
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
  abort();
}

/* ===================================================================
 * Machine_* functions (machine.h)
 * =================================================================== */

/* USB Device (stubs) */
void
Machine_tud_task(void)
{
}

bool
Machine_tud_mounted_q(void)
{
  return false;
}

/* Timing. emscripten_get_now() returns milliseconds as a double. The busy
 * waits spin the (single) browser thread, so callers must keep them short. */
void
Machine_busy_wait_us(uint32_t us)
{
  double deadline = emscripten_get_now() + (double)us / 1000.0;
  while (emscripten_get_now() < deadline) {
  }
}

void
Machine_busy_wait_ms(uint32_t ms)
{
  Machine_busy_wait_us(ms * 1000);
}

void
Machine_delay_ms(uint32_t ms)
{
  Machine_busy_wait_us(ms * 1000);
}

uint64_t
Machine_uptime_us(void)
{
  return (uint64_t)(emscripten_get_now() * 1000.0);
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

/* System */
bool
Machine_get_unique_id(char *id_str)
{
  /* The board returns a 16-hex-digit chip id. Browsers have no equivalent, so
   * report a fixed identifier (buffer is sized for 16 hex digits + NUL). */
  strcpy(id_str, "HARUCOMWASM00001");
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

EM_JS(void, harucom_js_reboot, (void), {
  if (typeof location !== "undefined" && location.reload) {
    location.reload();
  }
});

void
Machine_reboot(void)
{
  harucom_js_reboot();
}

/* Sleep */
void
Machine_sleep(uint32_t seconds)
{
  (void)seconds;
}

void
Machine_deep_sleep(uint8_t gpio_pin, bool edge, bool high)
{
  (void)gpio_pin;
  (void)edge;
  (void)high;
}

/* Hardware clock: emscripten provides clock_gettime for the wall clock. The
 * browser clock cannot be set, so Machine_set_hwclock is a no-op. */
bool
Machine_set_hwclock(const struct timespec *ts)
{
  (void)ts;
  return false;
}

bool
Machine_get_hwclock(struct timespec *ts)
{
  return clock_gettime(CLOCK_REALTIME, ts) == 0;
}
