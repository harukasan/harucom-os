// Copyright (c) 2026 Shunsuke Michii
//
// Browser (emscripten) DMX port.
//
// The board port paces a UART through DMA at 40 Hz, holding the line in a
// BREAK between frames. A browser has no wire to hold, so this port keeps the
// bookkeeping the engine exposes and drops the transmission. The universe
// itself lives in src/dmx.c, so DMX.set and DMX.get behave the way they do on
// the board and the on-screen universe view reads real values.
//
// The dead-man switch is not reproduced. It exists to darken a rig that a hung
// VM would otherwise leave lit, and there is no rig on this side.

#ifdef __EMSCRIPTEN__

#include <emscripten.h>

#include "dmx.h"

// The board engine's frame rate, kept so frame_count advances at the rate a
// show written against it expects.
#define DMX_FRAME_INTERVAL_MS 25.0 // 40 Hz

static bool running = false;
static double started_ms = 0.0;
static uint32_t frames_before_stop = 0;

int
dmx_init(const char *unit_name, int txd_pin)
{
  (void)unit_name;
  (void)txd_pin;
  // The board returns the DMA channel it claimed. Nothing is claimed here.
  return 0;
}

void
dmx_start(void)
{
  if (running) return;
  started_ms = emscripten_get_now();
  running = true;
}

void
dmx_stop(void)
{
  if (!running) return;
  frames_before_stop = dmx_frame_count();
  running = false;
}

uint32_t
dmx_frame_count(void)
{
  if (!running) return frames_before_stop;

  double elapsed = emscripten_get_now() - started_ms;
  return frames_before_stop + (uint32_t)(elapsed / DMX_FRAME_INTERVAL_MS);
}

void
dmx_keepalive(void)
{
  // Nothing to keep alive: see the note on the dead-man switch above.
}

void
dmx_set_deadman_ms(uint32_t ms)
{
  (void)ms;
}

#endif // __EMSCRIPTEN__
