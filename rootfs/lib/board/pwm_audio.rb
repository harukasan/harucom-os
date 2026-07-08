# Board::PWMAudio — PWM waveform synthesizer
#
# 3-channel audio output using PWM on the board's audio pins.
# Supports sine, square, triangle, and sawtooth waveforms.
# Output is DMA paced by the PWM wrap itself (50,000 Hz, one PWM
# period per sample); the
# engine renders autonomously in the DMA IRQ, so Ruby only changes
# tone parameters or schedules events.
#
# Usage:
#   audio = Board::PWMAudio.new
#   audio.tone(0, 440, waveform: Board::PWMAudio::SINE)
#   audio.stop(0)
#   at = audio.sample_clock + Board::PWMAudio::SAMPLE_RATE   # 1s ahead
#   audio.tone_at(at, 0, 880)
#   audio.stop_at(at + 4410, 0)
#   audio.deinit

module Board
  AUDIO_L_PIN = 24
  AUDIO_R_PIN = 25

  class PWMAudio
    SAMPLE_RATE = ::PWMAudio::SAMPLE_RATE

    SINE     = ::PWMAudio::SINE
    SQUARE   = ::PWMAudio::SQUARE
    TRIANGLE = ::PWMAudio::TRIANGLE
    SAWTOOTH = ::PWMAudio::SAWTOOTH

    # Musical note frequencies (Hz)
    C4  = 262; CS4 = 277; D4  = 294; DS4 = 311
    E4  = 330; F4  = 349; FS4 = 370; G4  = 392
    GS4 = 415; A4  = 440; AS4 = 466; B4  = 494
    C5  = 523; CS5 = 554; D5  = 587; DS5 = 622
    E5  = 659; F5  = 698; FS5 = 740; G5  = 784
    GS5 = 831; A5  = 880; AS5 = 932; B5  = 988
    C6  = 1047

    def initialize(l_pin: AUDIO_L_PIN, r_pin: AUDIO_R_PIN)
      ::PWMAudio.init(l_pin, r_pin)
    end

    # Play a tone on a channel (0-2).
    def tone(channel, frequency, waveform: SQUARE, volume: 15)
      ::PWMAudio.tone(channel, frequency, waveform, volume)
    end

    # Set pan for a channel. 0=L, 8=center, 15=R.
    def pan(channel, value)
      ::PWMAudio.pan(channel, value)
    end

    # Mute/unmute a channel.
    def mute(channel, flag)
      ::PWMAudio.mute(channel, flag)
    end

    # Stop a single channel.
    def stop(channel)
      ::PWMAudio.stop(channel)
    end

    # Stop all channels.
    def stop_all
      ::PWMAudio.stop_all
    end

    # Kept for compatibility: the engine fills its own buffer from the
    # DMA IRQ, so this is a no-op.
    def update
      ::PWMAudio.update
    end

    # Current playback position in samples (monotonic, SAMPLE_RATE/s).
    def sample_clock
      ::PWMAudio.sample_clock
    end

    # Schedule a tone start at an absolute sample position. Returns
    # false when the event queue is full.
    def tone_at(sample, channel, frequency, waveform: SQUARE, volume: 15)
      ::PWMAudio.tone_at(sample, channel, frequency, waveform, volume)
    end

    # Schedule a channel stop at an absolute sample position.
    def stop_at(sample, channel)
      ::PWMAudio.stop_at(sample, channel)
    end

    # Drop scheduled events for a channel (call before retriggering so
    # a stale scheduled stop cannot cut the new note).
    def cancel_scheduled(channel)
      ::PWMAudio.cancel_scheduled(channel)
    end

    # Play a tone for a given duration, then stop. Blocking.
    def beep(channel, frequency, duration_ms, waveform: SQUARE, volume: 15)
      tone(channel, frequency, waveform: waveform, volume: volume)
      sleep_ms(duration_ms)
      stop(channel)
    end

    def deinit
      stop_all
      ::PWMAudio.deinit
    end
  end
end
