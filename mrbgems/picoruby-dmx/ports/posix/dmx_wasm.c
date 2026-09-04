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
// Two things the board does are deliberately absent. The dead-man switch
// exists to darken a rig that a hung VM would otherwise leave lit, and there
// is no rig on this side. The board also stretches a frame to 33.3 ms whenever
// the previous one is still in the DMA channel, which at 512 active slots is
// most of them, so its effective rate settles near 30 Hz. There is no DMA
// here to fall behind, so frames are counted at the nominal rate and a rate
// derived from dmx_frame_count() reads higher here than on the board.

#ifdef __EMSCRIPTEN__

#include <string.h>

#include <emscripten.h>

#include "dmx.h"

#define DMX_FRAME_INTERVAL_MS (DMX_FRAME_INTERVAL_US / 1000.0)

// The board's counter is a uint32_t that wraps. This port derives it from a
// double, and the cast below traps in wasm rather than wrapping, so the
// quotient is clamped to what the cast can hold.
#define DMX_FRAME_COUNT_MAX 4294967295.0

static bool initialized = false;
static bool running = false;
static double started_ms = 0.0;
static uint32_t frames_before_stop = 0;

int
dmx_init(const char *unit_name, int txd_pin)
{
  if (initialized) return 0;

  // Nothing is muxed here, but a show is usually written in the browser and
  // run on the board, so the arguments are rejected the way the board rejects
  // them. Which pins carry TX for which unit is board wiring and stays in the
  // board port, so this stops at the range the header documents.
  if (unit_name != NULL && unit_name[0] != '\0' &&
      strcmp(unit_name, "RP2040_UART0") != 0 &&
      strcmp(unit_name, "RP2040_UART1") != 0) {
    return DMX_INIT_ERR_UNIT;
  }
  if (DMX_MAX_TXD_PIN < txd_pin) return DMX_INIT_ERR_PIN;

  // Start from a dark universe, as the board does.
  dmx_blackout();
  initialized = true;
  // The board returns the DMA channel it claimed. Nothing is claimed here.
  return 0;
}

void
dmx_start(void)
{
  if (!initialized || running) return;

  // The board darkens here too: its first frames overwrite whatever the
  // fixtures latched.
  dmx_blackout();
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

  double frames = (emscripten_get_now() - started_ms) / DMX_FRAME_INTERVAL_MS;
  if (frames < 0.0) frames = 0.0;
  if (DMX_FRAME_COUNT_MAX < frames) frames = DMX_FRAME_COUNT_MAX;
  return frames_before_stop + (uint32_t)frames;
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
