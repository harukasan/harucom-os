#ifndef PWM_AUDIO_DEFINED_H_
#define PWM_AUDIO_DEFINED_H_

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One sample spans exactly five carrier periods: a pin-less pacer
 * slice wraps once per sample and its DREQ paces the DMA that writes
 * the CC register, so every sample boundary lands at a fixed phase of
 * the carrier (any other ratio or phase beats audibly; see
 * doc/pwm-audio.md). The sample rate must divide clk_sys exactly:
 * 250 MHz has no factor 3, so 48k/44.1k/24k are impossible, and 50000
 * divides it. pwm_audio_init() checks the divisibility at runtime and
 * warns if the clock changes. */
#define PWM_AUDIO_SAMPLE_RATE  50000
#define PWM_AUDIO_CARRIER_HZ   250000
#define PWM_AUDIO_PWM_WRAP     999
#define PWM_AUDIO_NUM_CHANNELS 3

typedef enum {
  PWM_AUDIO_WAVE_SINE = 0,
  PWM_AUDIO_WAVE_SQUARE,
  PWM_AUDIO_WAVE_TRIANGLE,
  PWM_AUDIO_WAVE_SAWTOOTH,
} pwm_audio_waveform_t;

typedef struct {
  uint32_t phase;
  uint32_t phase_increment;
  uint8_t waveform; /* pwm_audio_waveform_t */
  uint8_t volume;   /* 0-15 */
  uint8_t pan;      /* 0-15: 0=L, 8=center, 15=R */
  bool muted;
} pwm_audio_channel_t;

/* Sample buffer: one ring played end to end by a single endless DMA
 * channel (read ring wrap), so the transfer cadence has no seams.
 * Each word is in PWM CC register format so the DMA can write it to
 * the slice CC register unmodified. */
#define PWM_AUDIO_BUF_BITS  11
#define PWM_AUDIO_BUF_SIZE  (1u << PWM_AUDIO_BUF_BITS) /* 2048 samples (~41 ms) */
#define PWM_AUDIO_BUF_MASK  (PWM_AUDIO_BUF_SIZE - 1)

extern uint32_t pwm_audio_buf[PWM_AUDIO_BUF_SIZE];

/* Set by the port: true when the L pin is PWM channel A, so the packer
 * knows which half-word of the CC register gets which side. */
extern bool pwm_audio_l_is_pwm_a;

/* Waveform generation and mixing (platform-independent) */
void pwm_audio_calc_sample(uint16_t *out_l, uint16_t *out_r);

/* Render count samples starting at start_sample on the playback
 * timeline into dst, applying scheduled events at their exact sample
 * positions. Called from the render pump ahead of the DMA reader. */
void pwm_audio_render_block(uint64_t start_sample, uint32_t *dst, uint32_t count);

/* Channel control (immediate; applied to samples rendered after the
 * call) */
void pwm_audio_set_tone(uint8_t channel, uint32_t frequency, uint8_t waveform, uint8_t volume);
void pwm_audio_set_pan(uint8_t channel, uint8_t pan);
void pwm_audio_set_mute(uint8_t channel, bool mute);
void pwm_audio_stop_channel(uint8_t channel);
void pwm_audio_stop_all(void);

/* Sample-accurate scheduling. when is an absolute position on the
 * playback timeline (compare with pwm_audio_sample_clock()). frequency
 * 0 schedules a channel stop. Returns false when the queue is full. */
bool pwm_audio_schedule(uint64_t when, uint8_t channel, uint32_t frequency,
                        uint8_t waveform, uint8_t volume);

/* Drop scheduled events for one channel (a retrigger must not be cut
 * by a stale scheduled stop). */
void pwm_audio_cancel_scheduled(uint8_t channel);

/* Platform-specific: current playback position in samples (monotonic,
 * advances at PWM_AUDIO_SAMPLE_RATE). */
uint64_t pwm_audio_sample_clock(void);

/* Platform-specific: render health counters. min_lead is the lowest
 * observed distance (samples) between the render position and the DMA
 * reader at pump entry (0 or negative means the reader hit unrendered
 * data = underrun). max_gap_us is the longest interval between pump
 * runs. drift_now/drift_min compare consumed samples against the
 * wall-clock expectation; a stall that loses output time steps them
 * toward negative without recovery. */
void pwm_audio_stats(int32_t *min_lead, uint32_t *max_gap_us, int32_t *drift_now,
                     int32_t *drift_min);

/* Platform-specific: short critical section guarding the event queue
 * and channel state against the render IRQ. */
uint32_t pwm_audio_lock(void);
void pwm_audio_unlock(uint32_t state);

/* Platform-specific init/deinit */
void pwm_audio_init(uint8_t l_pin, uint8_t r_pin);
void pwm_audio_deinit(void);

#ifdef __cplusplus
}
#endif

#endif /* PWM_AUDIO_DEFINED_H_ */
