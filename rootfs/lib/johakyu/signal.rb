# Continuous signals for the Johakyu pattern core.
#
# A signal is a Pattern whose query returns one Hap covering the query
# span, valued by sampling a function at the span midpoint. Signals have
# no whole, so they never produce onsets; discretize them with
# Pattern#segment or stream them through a continuous scheduler binding.
#
#   Johakyu.sine.slow(4)                # slow pan sweep source
#   Johakyu.saw.segment(8)              # 8 discrete steps per cycle
#   Johakyu.tri.range(0.2, 0.8)         # rescaled to 0.2..0.8
#
# Signal keeps the value function in the Float domain. The scheduler
# samples continuous tracks through sample(), which stays in Float
# arithmetic instead of querying: the query path allocates a Fraction,
# TimeSpan, and Hap per combinator layer per sample, and on the board
# (PSRAM heap) that GC pressure dominated the tick cost.
# fast/slow/range fold into three Float coefficients instead of
# wrapping blocks, so a chain like sine.range(0.2, 0.8).slow(8) costs
# one block call and three Float operations per sample (mruby block
# calls are comparatively expensive). Other transforms fall back to
# Pattern and stay correct through the query path.

require "johakyu/pattern"

module Johakyu
  TWO_PI = 6.283185307179586

  class Signal < Pattern
    # sample(t) = value_offset + value_scale * func(t * time_scale + time_offset)
    def initialize(func = nil, time_scale = 1.0, value_scale = 1.0, value_offset = 0.0,
                   time_offset = 0.0, &block)
      @func = func || block
      @time_scale = time_scale
      @value_scale = value_scale
      @value_offset = value_offset
      @time_offset = time_offset
    end

    # Signals answer queries by overriding this method instead of
    # storing a query proc like Pattern.new does.
    def query(span)
      [Hap.new(nil, span, sample(span.midpoint.to_f))]
    end

    def continuous?
      true
    end

    # Float fast path: no Fraction or Hap allocation.
    def sample(position)
      @value_offset + @value_scale * @func.call(position * @time_scale + @time_offset)
    end

    def fast(factor)
      f = factor.to_f
      raise ArgumentError, "fast factor must be positive" if f <= 0
      result = Signal.new(@func, @time_scale * f, @value_scale, @value_offset, @time_offset)
      result.sig = @sig && "fast:#{f}(#{@sig})"
      result
    end

    def slow(factor)
      fast(1.0 / factor.to_f)
    end

    # Shift later by amount cycles, folded into the time coefficients:
    # sampling at t must read the function at (t - amount).
    def late(amount)
      k = amount.to_f
      result = Signal.new(@func, @time_scale, @value_scale, @value_offset,
                          @time_offset - k * @time_scale)
      result.sig = @sig && "late:#{k}(#{@sig})"
      result
    end

    def early(amount)
      late(-amount.to_f)
    end

    # Rescale the sampled value to min..max. Folds into the linear
    # coefficients: min + (offset + scale * f) * (max - min).
    def range(min, max)
      span = (max - min).to_f
      result = Signal.new(@func, @time_scale,
                          @value_scale * span, min + @value_offset * span, @time_offset)
      result.sig = @sig && "range:#{min},#{max}(#{@sig})"
      result
    end

    def with_value(&block)
      source = self
      Signal.new { |t| block.call(source.sample(t)) }
    end

    # Signals discretize through the fast path below instead of the
    # generic Pattern#segment.
    def segment(n)
      SegmentedSignal.new(self, n)
    end
  end

  # Discrete segment fast path for signals: n Haps per cycle valued
  # directly through Signal#sample, skipping the generic segment
  # machinery (span_cycles split, one inner query and intersection per
  # step). Values match the generic path exactly: the sample at each
  # whole's midpoint.
  class SegmentedSignal < Pattern
    def initialize(signal, n)
      @signal = signal
      @n = n
      self.sig = signal.sig && "seg:#{n}(#{signal.sig})"
    end

    def query(span)
      b = span.begin_time
      e = span.end_time
      return [] if e <= b
      n = @n
      haps = []
      # First segment index overlapping the span: floor(b * n) in
      # integer math, no Rational temporaries.
      j = (b.numerator * n).div(b.denominator)
      ws = Rational(j, n)
      while ws < e
        we = Rational(j + 1, n)
        part_b = ws > b ? ws : b
        part_e = we < e ? we : e
        haps << Hap.new(TimeSpan.new(ws, we), TimeSpan.new(part_b, part_e),
                        value_at((j + 0.5) / n))
        ws = we
        j += 1
      end
      haps
    end

    private

    # Hook for subclasses that wrap the sampled value (see
    # SignalControl in control.rb).
    def value_at(position)
      @signal.sample(position)
    end
  end

  # Build a continuous pattern from a block of cycle position (Float).
  def self.signal(&func)
    Signal.new(&func)
  end

  # A named factory result is fully determined by its name, so it
  # carries the name as its change signature (see Pattern#sig).
  def self.named_signal(name, &func)
    result = Signal.new(&func)
    result.sig = name
    result
  end

  # Rising ramp 0..1 each cycle.
  def self.saw
    named_signal("saw") { |t| t - t.floor }
  end

  # Falling ramp 1..0 each cycle.
  def self.isaw
    named_signal("isaw") { |t| 1.0 - (t - t.floor) }
  end

  # Sine mapped to 0..1, starting at 0.5 rising.
  def self.sine
    named_signal("sine") { |t| 0.5 + 0.5 * Math.sin(TWO_PI * t) }
  end

  # Cosine mapped to 0..1.
  def self.cosine
    named_signal("cosine") { |t| 0.5 + 0.5 * Math.cos(TWO_PI * t) }
  end

  # Triangle 0..1..0 each cycle.
  def self.tri
    named_signal("tri") do |t|
      phase = t - t.floor
      phase < 0.5 ? phase * 2.0 : 2.0 - phase * 2.0
    end
  end

  # Square: 0 for the first half cycle, 1 for the second.
  def self.square_signal
    named_signal("square_signal") { |t| (t - t.floor) < 0.5 ? 0.0 : 1.0 }
  end
end
