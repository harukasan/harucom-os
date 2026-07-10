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
# Everything musical lives here in Ruby: the vocabulary, the filter
# coefficient math, and the drum definitions (synth/drum_kit.rb), so
# sounds are edited in one place for every platform. The per-sample
# loops run through a small fixed kernel set with two interchangeable
# backends: Synth::Native (the picoruby-synth-native gem,
# single-precision C, tens of milliseconds per drum on the board) and
# Synth::Kernels (pure
# Ruby, used on host CRuby). The kernels carry no musical meaning and
# do not change when sounds do.
#
# Rendering is deterministic: the same seed produces the same bytes on
# a given backend (noise comes from a seeded xorshift, not the system
# RNG). Pass seed: RNG.random_int on the board for a different noise
# take each time. Backends are sound-identical but not bit-identical
# (float vs double). See doc/synth.md.
module Synth
  DEFAULT_SEED = 0x4A4F4841

  # The classic metallic hihat source, TR-808 style: six square waves
  # in the 200-800 Hz band. Their stacked overtones form dense
  # inharmonic hash in the highs; the hat definitions then carve the
  # 8-10 kHz region out of it, which removes the tonal fundamentals
  # (kept low here so a bandpass can reject them completely).
  HIHAT_PARTIALS = [204.0, 298.0, 366.0, 515.0, 540.0, 800.0]

  SINE_SHAPE = 0
  SQUARE_SHAPE = 1

  native_found = false
  begin
    Native
    native_found = true
  rescue NameError
    native_found = false
  end
  NATIVE_AVAILABLE = native_found

  @use_native = NATIVE_AVAILABLE

  def self.native?
    @use_native
  end

  # Backend toggle, mainly for tests comparing the two.
  def self.use_native=(flag)
    @use_native = flag && NATIVE_AVAILABLE
  end

  def self.kernels
    @use_native ? NativeKernels : Kernels
  end

  # Seed holder for the noise kernel. Kept tiny: the drawing loop
  # itself is a kernel.
  class Random
    attr_accessor :state

    def initialize(seed)
      @state = seed & 0xFFFFFFFF
      @state = 0x9E3779B9 if @state == 0
    end
  end

  # Pure-Ruby kernels over Float Arrays. Synth::Native implements the
  # same set (same math, same xorshift sequence) in C; the two must
  # stay in step.
  module Kernels
    def self.constant(length, value)
      Array.new(length, value)
    end

    # base + amount * exp(-t * curve)
    def self.exp_curve(length, rate, base, amount, curve)
      out = Array.new(length)
      i = 0
      while i < length
        t = i.to_f / rate
        out[i] = base + amount * Math.exp(-t * curve)
        i += 1
      end
      out
    end

    # Zero before `at` seconds, exp(-t * decay) * level after it,
    # silenced past `cut` seconds relative to `at` (cut < 0: no cut).
    # Offsets round to whole samples ((rate * at).to_i would truncate
    # 1000 * 0.003 to 2).
    def self.envelope(length, rate, decay, at, cut, level)
      out = Array.new(length, 0.0)
      start = (rate * at).round
      stop = cut >= 0 ? start + (rate * cut).round : length - 1
      stop = length - 1 if stop > length - 1
      i = start
      while i <= stop
        t = (i - start).to_f / rate
        out[i] = Math.exp(-t * decay) * level
        i += 1
      end
      out
    end

    # xorshift32 noise in (-1.0, 1.0); returns [samples, new_state].
    def self.noise(length, state)
      out = Array.new(length)
      x = state
      i = 0
      while i < length
        x = (x ^ (x << 13)) & 0xFFFFFFFF
        x ^= (x >> 17)
        x = (x ^ (x << 5)) & 0xFFFFFFFF
        out[i] = x.to_f / 2147483648.0 - 1.0
        i += 1
      end
      [out, x]
    end

    # Phase-accumulated oscillator over a per-sample frequency curve.
    def self.oscillate(freqs, rate, shape)
      out = Array.new(freqs.length)
      phase = 0.0
      i = 0
      if shape == SINE_SHAPE
        while i < freqs.length
          phase += 2.0 * Math::PI * freqs[i] / rate
          out[i] = Math.sin(phase)
          i += 1
        end
      else
        # Integer phase in 1/2^32 turns, like the xorshift noise:
        # exact and identical in every backend. A float phase
        # accumulator drifts between float widths (boxed VM floats
        # truncate mantissa bits) and a drifted square flips whole
        # samples at its edges.
        acc = 0
        scale = 4294967296.0 / rate
        while i < freqs.length
          acc = (acc + (freqs[i] * scale + 0.5).to_i) & 0xFFFFFFFF
          out[i] = acc < 0x80000000 ? 1.0 : -1.0
          i += 1
        end
      end
      out
    end

    def self.mix(a, b)
      n = a.length > b.length ? a.length : b.length
      out = Array.new(n)
      i = 0
      while i < n
        va = i < a.length ? a[i] : 0.0
        vb = i < b.length ? b[i] : 0.0
        out[i] = va + vb
        i += 1
      end
      out
    end

    def self.multiply(a, b)
      out = Array.new(a.length)
      i = 0
      while i < a.length
        vb = i < b.length ? b[i] : 0.0
        out[i] = a[i] * vb
        i += 1
      end
      out
    end

    def self.gain(a, value)
      out = Array.new(a.length)
      i = 0
      while i < a.length
        out[i] = a[i] * value
        i += 1
      end
      out
    end

    # Direct form 1 biquad; coefficients come from the callers.
    def self.biquad(a, b0, b1, b2, a1, a2)
      out = Array.new(a.length)
      x1 = 0.0
      x2 = 0.0
      y1 = 0.0
      y2 = 0.0
      i = 0
      while i < a.length
        x = a[i]
        y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        out[i] = y
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        i += 1
      end
      out
    end

    def self.peak(a)
      max = 0.0
      i = 0
      while i < a.length
        v = a[i]
        v = -v if v < 0
        max = v if v > max
        i += 1
      end
      max
    end

    def self.fade_tail(a, samples)
      out = a.dup
      samples = out.length if samples > out.length
      start = out.length - samples
      i = 0
      while i < samples
        out[start + i] *= 1.0 - (i + 1).to_f / samples
        i += 1
      end
      out
    end

    def self.to_wav(a, rate)
      pcm_values = Array.new(a.length)
      i = 0
      while i < pcm_values.length
        v = a[i]
        v = 1.0 if v > 1.0
        v = -1.0 if v < -1.0
        pcm_values[i] = (v * 32767).round
        i += 1
      end
      pcm = pcm_values.pack("s<*")
      header = ["RIFF", 36 + pcm.bytesize, "WAVE",
                "fmt ", 16, 1, 1, rate, rate * 2, 2, 16,
                "data", pcm.bytesize].pack("a4Va4a4VvvVVvva4V")
      header + pcm
    end
  end

  # The same kernel signatures served by Synth::Native buffers.
  module NativeKernels
    def self.constant(length, value)
      Native.constant(length, value)
    end

    def self.exp_curve(length, rate, base, amount, curve)
      Native.exp_curve(length, rate, base, amount, curve)
    end

    def self.envelope(length, rate, decay, at, cut, level)
      Native.envelope(length, rate, decay, at, cut, level)
    end

    def self.noise(length, state)
      Native.noise(length, state)
    end

    def self.oscillate(freqs, rate, shape)
      freqs.oscillate(rate, shape)
    end

    def self.mix(a, b)
      a.mix(b)
    end

    def self.multiply(a, b)
      a.multiply(b)
    end

    def self.gain(a, value)
      a.gain(value)
    end

    def self.biquad(a, b0, b1, b2, a1, a2)
      a.biquad(b0, b1, b2, a1, a2)
    end

    def self.peak(a)
      a.peak
    end

    def self.fade_tail(a, samples)
      a.fade_tail(samples)
    end

    def self.to_wav(a, rate)
      a.to_wav(rate)
    end
  end

  # A mono signal (-1.0..1.0) at a sample rate. The backing store
  # comes from the active kernel backend; operations compute their
  # coefficients here and run whole-buffer kernel passes.
  class Buffer
    attr_reader :raw, :rate

    def initialize(raw, rate)
      @raw = raw
      @rate = rate
    end

    def samples
      @raw.is_a?(Array) ? @raw : @raw.to_a
    end

    def length
      @raw.length
    end

    # Mix; the result spans the longer operand.
    def +(other)
      Buffer.new(Synth.kernels.mix(@raw, other.raw), @rate)
    end

    # Scalar gain.
    def *(value)
      Buffer.new(Synth.kernels.gain(@raw, value), @rate)
    end

    # One-pole filters expressed as biquads, enough character for drum
    # shaping.
    def highpass(cutoff)
      k = 1.0 / (2.0 * Math::PI * cutoff / @rate + 1.0)
      Buffer.new(Synth.kernels.biquad(@raw, k, -k, 0.0, -k, 0.0), @rate)
    end

    def lowpass(cutoff)
      a = 2.0 * Math::PI * cutoff / @rate
      a = a / (a + 1.0)
      Buffer.new(Synth.kernels.biquad(@raw, a, 0.0, 0.0, -(1.0 - a), 0.0), @rate)
    end

    # Resonant bandpass (constant skirt gain); claps need a real
    # resonance to crack instead of hiss.
    def bandpass(center, q: 1.0)
      w = 2.0 * Math::PI * center / @rate
      alpha = Math.sin(w) / (2.0 * q)
      a0 = 1.0 + alpha
      Buffer.new(Synth.kernels.biquad(@raw, alpha / a0, 0.0, -alpha / a0,
                                      -2.0 * Math.cos(w) / a0, (1.0 - alpha) / a0), @rate)
    end

    # Exponential envelope starting at offset `at` seconds: zero
    # before it, exp(-t * decay) * level after it, silenced past `cut`
    # seconds (relative to `at`). Summing several env() of one source
    # at different offsets builds multi-attack shapes like handclaps.
    def env(decay, at: 0.0, cut: nil, level: 1.0)
      curve = Synth.kernels.envelope(@raw.length, @rate, decay, at, cut ? cut : -1.0, level)
      Buffer.new(Synth.kernels.multiply(@raw, curve), @rate)
    end

    def normalize(peak: 0.9)
      max = Synth.kernels.peak(@raw)
      return self if max == 0.0
      self * (peak / max)
    end

    # Fade the last few milliseconds so a one-shot ends exactly at
    # zero.
    def fade_tail(ms: 4.0)
      Buffer.new(Synth.kernels.fade_tail(@raw, (@rate * ms / 1000.0).round), @rate)
    end

    # 16-bit mono WAV.
    def to_wav
      Synth.kernels.to_wav(@raw, @rate)
    end
  end

  # Receiver of the render block: holds the rate and the noise seed so
  # the vocabulary reads without them.
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
      k = Synth.kernels
      freqs = k.exp_curve(n, @rate, to, from - to, curve)
      tone = k.oscillate(freqs, @rate, SINE_SHAPE)
      Buffer.new(k.multiply(tone, k.envelope(n, @rate, decay, 0.0, -1.0, 1.0)), @rate)
    end

    def noise(seconds, decay: 0.0)
      n = (@rate * seconds).round
      k = Synth.kernels
      drawn = k.noise(n, @random.state)
      @random.state = drawn[1]
      return Buffer.new(drawn[0], @rate) if decay == 0.0
      Buffer.new(k.multiply(drawn[0], k.envelope(n, @rate, decay, 0.0, -1.0, 1.0)), @rate)
    end

    def metallic(seconds, decay:, partials: Synth::HIHAT_PARTIALS)
      n = (@rate * seconds).round
      k = Synth.kernels
      sum = nil
      i = 0
      while i < partials.length
        tone = k.oscillate(k.constant(n, partials[i]), @rate, SQUARE_SHAPE)
        sum = sum ? k.mix(sum, tone) : tone
        i += 1
      end
      shaped = k.multiply(k.gain(sum, 1.0 / partials.length),
                          k.envelope(n, @rate, decay, 0.0, -1.0, 1.0))
      Buffer.new(shaped, @rate)
    end

    def silence(seconds)
      Buffer.new(Synth.kernels.constant((@rate * seconds).round, 0.0), @rate)
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
