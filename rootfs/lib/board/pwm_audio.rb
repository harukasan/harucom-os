# Board::PWMAudio: PWM audio output on the board's audio pins
#
# CHANNELS mixer channels, each playing an oscillator (sine, square,
# triangle, sawtooth) or a mono QOA sample, decoded on demand. The
# output is a wrap-paced DMA stream (50,000 samples/s) rendered
# autonomously in C, so Ruby only changes parameters or schedules
# events. See doc/pwm-audio.md for the design.
#
# Usage:
#   audio = Board::PWMAudio.new
#   audio.tone(0, 440, waveform: Board::PWMAudio::SINE)
#   audio.stop(0)
#
#   kick = PWMAudio::Sample.new(File.open("/data/kick.qoa", "r") { |f| f.read })
#   ch = audio.channel(3)
#   ch.source = kick
#   ch.play
#   ch.play_at(audio.sample_clock + Board::PWMAudio::SAMPLE_RATE / 2)
#   audio.deinit

module Board
  AUDIO_L_PIN = 24
  AUDIO_R_PIN = 25

  class PWMAudio
    SAMPLE_RATE = ::PWMAudio::SAMPLE_RATE
    CHANNELS    = ::PWMAudio::CHANNELS

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

    # Channel object (PWMAudio::Channel) from the shared pool; holds
    # a Sample or Tone source and plays it (see doc/pwm-audio.md).
    def channel(index)
      ::PWMAudio.channel(index)
    end

    # Play a tone on a channel (0...CHANNELS).
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
