/*
 * picoruby-dmx/src/dmx.c
 *
 * DMX512 universe buffer and accessors.
 * The universe lives in C so the DMA engine in ports/rp2350/dmx_port.c
 * reads it without involving the mruby VM. Ruby only updates values.
 * Channel arguments are 1-based (1..DMX_SLOTS); out-of-range writes are
 * ignored so a bad script cannot corrupt the start code.
 */

#include "../include/dmx.h"
#include <string.h>

#if defined(PICORB_VM_MRUBY)
#include "mruby/dmx.c"
#endif

/* [0] = start code (always 0x00), [1..DMX_SLOTS] = slot values */
volatile uint8_t dmx_universe[1 + DMX_SLOTS];
volatile uint16_t dmx_active_slots = DMX_SLOTS;

void
dmx_set(uint16_t channel, uint8_t value)
{
  if (channel < 1 || DMX_SLOTS < channel) return;
  dmx_universe[channel] = value;
}

void
dmx_set_range(uint16_t channel, const uint8_t *values, uint16_t count)
{
  if (channel < 1 || DMX_SLOTS < channel) return;
  if ((uint16_t)(DMX_SLOTS - channel + 1) < count) {
    count = (uint16_t)(DMX_SLOTS - channel + 1);
  }
  memcpy((void *)&dmx_universe[channel], values, count);
}

uint8_t
dmx_get(uint16_t channel)
{
  if (channel < 1 || DMX_SLOTS < channel) return 0;
  return dmx_universe[channel];
}

void
dmx_blackout(void)
{
  memset((void *)&dmx_universe[1], 0, DMX_SLOTS);
}

void
dmx_set_active_slots(uint16_t count)
{
  if (count < 1) count = 1;
  if (DMX_SLOTS < count) count = DMX_SLOTS;
  dmx_active_slots = count;
}
