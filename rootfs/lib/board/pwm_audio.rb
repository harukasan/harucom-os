# Board::PWMAudio — PWM waveform synthesizer
#
# 3-channel audio output using PWM on the board's audio pins.
# Supports sine, square, triangle, and sawtooth waveforms.
# Runs on Core 0 timer ISR (22,050 Hz sample rate, 250 kHz carrier).
#
# Usage:
#   audio = Board::PWMAudio.new
#   audio.tone(0, 440, waveform: Board::PWMAudio::SINE)
#   audio.update       # call every loop iteration to fill sample buffer
#   audio.stop(0)
#   audio.deinit

module Board
  AUDIO_L_PIN = 24
  AUDIO_R_PIN = 25

  class PWMAudio
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

    # Fill the sample ring buffer. Call every main loop iteration.
    def update
      ::PWMAudio.update
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
