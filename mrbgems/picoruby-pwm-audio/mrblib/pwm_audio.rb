# PWMAudio object layer: Channel + Sample/Tone sources, modeled after
# a DAW channel rack (each channel holds a sample or a synth source
# and plays it through shared verbs). The C module functions remain
# the flat low-level API; these classes wrap them without adding
# state to the engine.
#
#   audio = Board::PWMAudio.new
#   kick = PWMAudio::Sample.new(File.open("/data/kick.qoa", "r") { |f| f.read })
#   ch = audio.channel(3)
#   ch.source = kick
#   ch.play                              # one-shot
#   ch.play_at(audio.sample_clock + 25000)
#
#   lead = audio.channel(0)
#   lead.source = PWMAudio::Tone.new(440, waveform: PWMAudio::SINE)
#   lead.play                            # continuous until stop
#   lead.stop_at(audio.sample_clock + 5000)
#
# The engine state is authoritative: mixing the flat module functions
# and a Channel object on the same channel index can leave the
# object's #source stale, so use one style per channel.
module PWMAudio
  # A loaded sample, QOA or 16-bit PCM WAV, mono or stereo (detected
  # by header). Owns the file bytes, so a Sample referenced by a
  # Channel keeps its data alive for the engine.
  class Sample
    attr_reader :data, :samplerate, :frames, :channels

    def initialize(data)
      info = PWMAudio.sample_info(data)
      @data = data
      @samplerate = info[0]
      @frames = info[1]
      @channels = info[2]
    end

    # The default inspect dumps @data (kilobytes of escaped binary),
    # which takes seconds to print on the console.
    def inspect
      kind = @channels == 2 ? "stereo" : "mono"
      "#<PWMAudio::Sample #{@samplerate}Hz #{@frames} frames #{kind}>"
    end
  end

  # A file on the flash filesystem played by streaming. The file's
  # flash blocks are mapped once at creation (FlashFile.extents) and
  # the engine decodes straight from memory-mapped flash, so a track
  # larger than RAM plays with no buffer and no feeder task. The file
  # must not be rewritten while attached; writing it moves its blocks.
  class Stream
    attr_reader :path, :samplerate, :frames, :channels, :extents, :bytesize

    def initialize(path)
      @path = path
      result = FlashFile.extents(path)
      if result.nil?
        raise ArgumentError, "#{path} is stored inline; load it with Sample"
      end
      @extents = result[0]
      @bytesize = result[1]
      info = PWMAudio.stream_info(@extents, @bytesize)
      @samplerate = info[0]
      @frames = info[1]
      @channels = info[2]
    end

    def inspect
      kind = @channels == 2 ? "stereo" : "mono"
      "#<PWMAudio::Stream #{@path} #{@samplerate}Hz #{@frames} frames #{kind}>"
    end
  end

  # An oscillator source: frequency and waveform. A plain value
  # object; the engine is configured when the channel plays it.
  class Tone
    attr_reader :frequency, :waveform

    def initialize(frequency, waveform: SQUARE)
      @frequency = frequency
      @waveform = waveform
    end

    def inspect
      "#<PWMAudio::Tone #{@frequency}Hz>"
    end
  end

  # One mixer channel. play/play_at dispatch on the source kind: a
  # Tone starts the oscillator (continuous until stop), a Sample
  # plays one-shot from the start.
  class Channel
    attr_reader :index, :source
    attr_accessor :volume

    def initialize(index)
      @index = index
      @volume = 15
    end

    # Assign the playback source. A Sample or Stream is attached to
    # the engine immediately; a Tone is kept and sent when played.
    def source=(source)
      if source.is_a?(Sample)
        PWMAudio.set_sample(@index, source.data)
      elsif source.is_a?(Stream)
        PWMAudio.set_stream(@index, source.extents, source.bytesize)
      end
      @source = source
    end

    def play(volume: @volume)
      source = @source
      if source.is_a?(Tone)
        PWMAudio.tone(@index, source.frequency, source.waveform, volume)
      else
        PWMAudio.play(@index, volume)
      end
    end

    def play_at(at, volume: @volume)
      source = @source
      if source.is_a?(Tone)
        PWMAudio.tone_at(at, @index, source.frequency, source.waveform, volume)
      else
        PWMAudio.play_at(at, @index, volume)
      end
    end

    # Compatibility sugar: set an oscillator source and start it.
    def tone(frequency, waveform: SQUARE, volume: @volume)
      @source = Tone.new(frequency, waveform: waveform)
      PWMAudio.tone(@index, frequency, waveform, volume)
    end

    def tone_at(at, frequency, waveform: SQUARE, volume: @volume)
      @source = Tone.new(frequency, waveform: waveform)
      PWMAudio.tone_at(at, @index, frequency, waveform, volume)
    end

    def stop
      PWMAudio.stop(@index)
    end

    def stop_at(at)
      PWMAudio.stop_at(at, @index)
    end

    def pan=(value)
      PWMAudio.pan(@index, value)
    end

    def mute=(flag)
      PWMAudio.mute(@index, flag)
    end

    def cancel_scheduled
      PWMAudio.cancel_scheduled(@index)
    end

    # Keep inspect compact: the default would dump the source chain,
    # including a Sample's binary data.
    def inspect
      "#<PWMAudio::Channel #{@index} #{@source.inspect}>"
    end
  end

  # Fixed channel pool: the hardware mixer is one instance, so every
  # caller shares the same Channel objects (this also keeps each
  # channel's Sample referenced). Reached through
  # Board::PWMAudio#channel.
  def self.channel(index)
    if index < 0 || index >= CHANNELS
      raise ArgumentError, "invalid channel #{index}"
    end
    @channels ||= Array.new(CHANNELS)
    @channels[index] ||= Channel.new(index)
  end
end
