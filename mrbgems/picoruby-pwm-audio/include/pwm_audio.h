#ifndef PWM_AUDIO_DEFINED_H_
#define PWM_AUDIO_DEFINED_H_

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PWM_AUDIO_SAMPLE_RATE  22050
#define PWM_AUDIO_CARRIER_HZ   250000
#define PWM_AUDIO_PWM_WRAP     499 /* 125 MHz / 250 kHz */
#define PWM_AUDIO_NUM_CHANNELS 3

typedef enum {
  PWM_AUDIO_WAVE_SINE = 0,
  PWM_AUDIO_WAVE_SQUARE,
  PWM_AUDIO_WAVE_TRIANGLE,
  PWM_AUDIO_WAVE_SAWTOOTH,
} pwm_audio_waveform_t;

/* Per-channel attack/release amplitude ramp. The waveform is unsigned (a large
 * DC offset), so starting or stopping a note abruptly steps that DC and clicks.
 * Ramp a gain (0..ENV_MAX) toward env_target over ENV_MAX/ENV_STEP samples so the
 * whole waveform (DC included) fades in/out, declicking note on/off. */
#define PWM_AUDIO_ENV_BITS 12
#define PWM_AUDIO_ENV_MAX  (1u << PWM_AUDIO_ENV_BITS) /* unity gain */
#define PWM_AUDIO_ENV_STEP 64                         /* ~2.9 ms ramp at 22050 Hz */

typedef struct {
  uint32_t phase;
  uint32_t phase_increment;
  uint16_t env;        /* current ramp gain, 0..PWM_AUDIO_ENV_MAX */
  uint16_t env_target; /* ramp destination: ENV_MAX when sounding, 0 when off */
  uint8_t waveform; /* pwm_audio_waveform_t */
  uint8_t volume;   /* 0-15 */
  uint8_t pan;      /* 0-15: 0=L, 8=center, 15=R */
  bool muted;
} pwm_audio_channel_t;

/* Sample buffer (ring buffer, power-of-2 size) */
#define PWM_AUDIO_BUF_BITS 10
#define PWM_AUDIO_BUF_SIZE (1u << PWM_AUDIO_BUF_BITS) /* 1024 samples (~46 ms) */
#define PWM_AUDIO_BUF_MASK (PWM_AUDIO_BUF_SIZE - 1)

/* Packed stereo sample: upper 16 bits = L, lower 16 bits = R */
extern uint32_t pwm_audio_buf[PWM_AUDIO_BUF_SIZE];
extern volatile uint32_t pwm_audio_wr; /* written by renderer */
extern volatile uint32_t pwm_audio_rd; /* written by ISR */

/* Waveform generation and mixing (platform-independent) */
void pwm_audio_calc_sample(uint16_t *out_l, uint16_t *out_r);

/* Render samples into the ring buffer. Call from main loop. */
void pwm_audio_fill_buffer(void);

/* Channel control */
void pwm_audio_set_tone(uint8_t channel, uint32_t frequency, uint8_t waveform, uint8_t volume);
void pwm_audio_set_pan(uint8_t channel, uint8_t pan);
void pwm_audio_set_mute(uint8_t channel, bool mute);
void pwm_audio_stop_channel(uint8_t channel);
void pwm_audio_stop_all(void);

/* Platform-specific init/deinit */
void pwm_audio_init(uint8_t l_pin, uint8_t r_pin);
void pwm_audio_deinit(void);

#ifdef __cplusplus
}
#endif

#endif /* PWM_AUDIO_DEFINED_H_ */
