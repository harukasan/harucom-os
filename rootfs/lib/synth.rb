# Synth: sample synthesis as Ruby code, shared between the board and
# the host. Synth.render evaluates a block of synthesis vocabulary and
# returns a 16-bit mono WAV String, ready for PWMAudio::Sample.new on
# the board or File.write on the host:
#
#   kick = PWMAudio::Sample.new(Synth.render(rate: 44100) {
#     sweep(0.28, from: 160, to: 44, curve: 28, decay: 12) +
#       noise(0.02, decay: 300).highpass(900) * 0.5
#   })
#
# Rendering is deterministic: the same seed produces the same bytes on
# any platform running this file (noise comes from the xorshift below,
# not the system RNG). Pass seed: RNG.random_int on the board for a
# different noise take each time. See doc/synth.md for the design.
module Synth
  DEFAULT_SEED = 0x4A4F4841

  # The classic metallic hihat source: six detuned square partials.
  HIHAT_PARTIALS = [2126.0, 3219.0, 3386.0, 3811.0, 4740.0, 6788.0]

  # Deterministic xorshift32. The system RNG (picoruby-rng) cannot be
  # seeded and does not exist on host CRuby, so noise uses this
  # instead; renders then reproduce bit for bit.
  class Random
    def initialize(seed)
      @state = seed & 0xFFFFFFFF
      @state = 0x9E3779B9 if @state == 0
    end

    # Uniform in (-1.0, 1.0).
    def next_float
      x = @state
      x = (x ^ (x << 13)) & 0xFFFFFFFF
      x ^= (x >> 17)
      x = (x ^ (x << 5)) & 0xFFFFFFFF
      @state = x
      x.to_f / 2147483648.0 - 1.0
    end
  end

  # A mono float signal (-1.0..1.0) at a sample rate. Operations
  # return new Buffers; each one is a coarse whole-buffer pass, which
  # keeps the door open for a C-backed implementation later.
  class Buffer
    attr_reader :samples, :rate

    def initialize(samples, rate)
      @samples = samples
      @rate = rate
    end

    def length
      @samples.length
    end

    # Mix; the result spans the longer operand.
    def +(other)
      a = @samples
      b = other.samples
      n = a.length > b.length ? a.length : b.length
      out = Array.new(n)
      i = 0
      while i < n
        va = i < a.length ? a[i] : 0.0
        vb = i < b.length ? b[i] : 0.0
        out[i] = va + vb
        i += 1
      end
      Buffer.new(out, @rate)
    end

    # Scalar gain.
    def *(gain)
      out = Array.new(@samples.length)
      i = 0
      while i < out.length
        out[i] = @samples[i] * gain
        i += 1
      end
      Buffer.new(out, @rate)
    end

    # One-pole filters, enough character for drum shaping.
    def highpass(cutoff)
      k = 1.0 / (2.0 * Math::PI * cutoff / @rate + 1.0)
      out = Array.new(@samples.length)
      prev_x = 0.0
      prev_y = 0.0
      i = 0
      while i < out.length
        x = @samples[i]
        y = k * (prev_y + x - prev_x)
        out[i] = y
        prev_x = x
        prev_y = y
        i += 1
      end
      Buffer.new(out, @rate)
    end

    def lowpass(cutoff)
      a = 2.0 * Math::PI * cutoff / @rate
      a = a / (a + 1.0)
      out = Array.new(@samples.length)
      prev = 0.0
      i = 0
      while i < out.length
        prev += a * (@samples[i] - prev)
        out[i] = prev
        i += 1
      end
      Buffer.new(out, @rate)
    end

    # Second-order resonant bandpass (biquad, constant skirt gain);
    # claps need a real resonance to crack instead of hiss.
    def bandpass(center, q: 1.0)
      w = 2.0 * Math::PI * center / @rate
      alpha = Math.sin(w) / (2.0 * q)
      a0 = 1.0 + alpha
      b0 = alpha / a0
      b2 = -alpha / a0
      a1 = -2.0 * Math.cos(w) / a0
      a2 = (1.0 - alpha) / a0
      out = Array.new(@samples.length)
      x1 = 0.0
      x2 = 0.0
      y1 = 0.0
      y2 = 0.0
      i = 0
      while i < out.length
        x = @samples[i]
        y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        out[i] = y
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        i += 1
      end
      Buffer.new(out, @rate)
    end

    # Exponential envelope starting at offset `at` seconds: zero
    # before it, exp(-t * decay) * level after it, silenced past `cut`
    # seconds (relative to `at`). Summing several env() of one source
    # at different offsets builds multi-attack shapes like handclaps.
    # Offsets round to whole samples ((rate * at).to_i would truncate
    # 1000 * 0.003 to 2).
    def env(decay, at: 0.0, cut: nil, level: 1.0)
      out = Array.new(@samples.length, 0.0)
      start = (@rate * at).round
      stop = cut ? start + (@rate * cut).round : out.length - 1
      stop = out.length - 1 if stop > out.length - 1
      i = start
      while i <= stop
        t = (i - start).to_f / @rate
        out[i] = @samples[i] * Math.exp(-t * decay) * level
        i += 1
      end
      Buffer.new(out, @rate)
    end

    def normalize(peak: 0.9)
      max = 0.0
      i = 0
      while i < @samples.length
        v = @samples[i]
        v = -v if v < 0
        max = v if v > max
        i += 1
      end
      return self if max == 0.0
      self * (peak / max)
    end

    # Fade the last few milliseconds so a one-shot ends exactly at
    # zero.
    def fade_tail(ms: 4.0)
      out = @samples.dup
      n = (@rate * ms / 1000.0).round
      n = out.length if n > out.length
      start = out.length - n
      i = 0
      while i < n
        out[start + i] *= 1.0 - (i + 1).to_f / n
        i += 1
      end
      Buffer.new(out, @rate)
    end

    # 16-bit mono WAV.
    def to_wav
      pcm_values = Array.new(@samples.length)
      i = 0
      while i < pcm_values.length
        v = @samples[i]
        v = 1.0 if v > 1.0
        v = -1.0 if v < -1.0
        pcm_values[i] = (v * 32767).round
        i += 1
      end
      pcm = pcm_values.pack("s<*")
      header = ["RIFF", 36 + pcm.bytesize, "WAVE",
                "fmt ", 16, 1, 1, @rate, @rate * 2, 2, 16,
                "data", pcm.bytesize].pack("a4Va4a4VvvVVvva4V")
      header + pcm
    end
  end

  # Receiver of the render block: holds the rate and the noise source
  # so the vocabulary reads without them.
  class Context
    def initialize(rate, random)
      @rate = rate
      @random = random
    end

    # Damped sine with an exponential pitch sweep, the body of kicks,
    # toms, and snare shells. `curve` is the sweep rate; `to` defaults
    # to `from` (no sweep).
    def sweep(seconds, from:, to: nil, curve: 0.0, decay:)
      to = from if to.nil?
      n = (@rate * seconds).round
      out = Array.new(n)
      phase = 0.0
      i = 0
      while i < n
        t = i.to_f / @rate
        freq = to + (from - to) * Math.exp(-t * curve)
        phase += 2.0 * Math::PI * freq / @rate
        out[i] = Math.sin(phase) * Math.exp(-t * decay)
        i += 1
      end
      Buffer.new(out, @rate)
    end

    def noise(seconds, decay: 0.0)
      n = (@rate * seconds).round
      out = Array.new(n)
      i = 0
      while i < n
        t = i.to_f / @rate
        out[i] = @random.next_float * Math.exp(-t * decay)
        i += 1
      end
      Buffer.new(out, @rate)
    end

    def metallic(seconds, decay:, partials: HIHAT_PARTIALS)
      n = (@rate * seconds).round
      phases = Array.new(partials.length, 0.0)
      out = Array.new(n)
      i = 0
      while i < n
        t = i.to_f / @rate
        v = 0.0
        p = 0
        while p < partials.length
          phase = phases[p] + partials[p] / @rate
          phase -= 1.0 if phase >= 1.0
          phases[p] = phase
          v += phase < 0.5 ? 1.0 : -1.0
          p += 1
        end
        out[i] = v / partials.length * Math.exp(-t * decay)
        i += 1
      end
      Buffer.new(out, @rate)
    end

    def silence(seconds)
      Buffer.new(Array.new((@rate * seconds).round, 0.0), @rate)
    end
  end

  # Render a synthesis block to a WAV String. The block runs with a
  # Context as self and must return a Buffer; the result is
  # normalized and tail-faded.
  def self.render(rate: 44100, seed: DEFAULT_SEED, &block)
    context = Context.new(rate, Random.new(seed))
    result = context.instance_eval(&block)
    unless result.is_a?(Buffer)
      raise ArgumentError, "render block must return a Synth::Buffer"
    end
    result.normalize.fade_tail.to_wav
  end
end
