#ifndef DMX_DEFINED_H_
#define DMX_DEFINED_H_

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DMX_SLOTS 512

/* Universe buffer: [0] = start code (always 0x00), [1..512] = slot values.
 * Owned by C so the background DMA engine can read it without the VM.
 * Ruby only updates slot values. */
extern volatile uint8_t dmx_universe[1 + DMX_SLOTS];

/* Number of slots sent per frame (1..DMX_SLOTS). Shorter frames leave
 * more idle time between frames. */
extern volatile uint16_t dmx_active_slots;

/* Universe access (platform-independent, src/dmx.c) */
void dmx_set(uint16_t channel, uint8_t value);
void dmx_set_range(uint16_t channel, const uint8_t *values, uint16_t count);
uint8_t dmx_get(uint16_t channel);
void dmx_blackout(void);
void dmx_set_active_slots(uint16_t count);

/* Background transmit engine (platform-specific, ports/).
 * dmx_init configures the given UART unit and TX pin for DMX512
 * (250000 baud 8N2, fixed by the standard), claims a DMA channel and
 * the frame alarm pool, and returns the claimed DMA channel number.
 * A NULL or empty unit_name and a negative txd_pin select the board
 * default wiring from the board header. The engine only transmits,
 * so there is no receive pin. */
#define DMX_INIT_ERR_UNIT     (-1) /* unknown UART unit name */
#define DMX_INIT_ERR_RESOURCE (-2) /* no free DMA channel or alarm pool */
int dmx_init(const char *unit_name, int txd_pin);
void dmx_start(void); /* start 40 Hz background transmission */
void dmx_stop(void);  /* stop transmission (fixtures hold last values) */
uint32_t dmx_frame_count(void);

/* Dead-man switch: Ruby calls dmx_keepalive() from its main loop. When
 * the heartbeat stops for longer than deadman_ms, the engine forces the
 * universe to zero so a hung VM cannot leave the rig lit. */
void dmx_keepalive(void);
void dmx_set_deadman_ms(uint32_t ms); /* 0 disables, default 500 */

#ifdef __cplusplus
}
#endif

#endif /* DMX_DEFINED_H_ */
