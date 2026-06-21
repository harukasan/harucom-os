/*
 * WebAssembly port of picoruby-io-console.
 *
 * Browser counterpart of picoruby-io-console/ports/posix/io-console.c. There is
 * no tty in the browser, so the raw/cooked and echo state is tracked with plain
 * flags instead of termios. The cooked-mode line handling and echoing live in
 * hal_machine_wasm.c, which queries io_raw_q()/io_echo_q() exactly as the board
 * HAL does.
 */

#include <stdbool.h>

#include "io-console.h"

/* Mirrors the posix port: raw mode implies echo off; cooked mode implies echo
 * on. IO#echo= can override the echo flag independently. */
static bool raw_mode = false;
static bool echo_on = true;

bool
io_raw_q(void)
{
  return raw_mode;
}

void
io_raw_bang(bool nonblock)
{
  (void)nonblock;
  raw_mode = true;
  echo_on = false;
}

void
io_cooked_bang(void)
{
  raw_mode = false;
  echo_on = true;
}

void
io_echo_eq(bool flag)
{
  echo_on = flag;
}

bool
io_echo_q(void)
{
  return echo_on;
}

void
io__restore_termios(void)
{
}