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
# (boxed Floats, PSRAM heap) that GC pressure dominated the tick cost.
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
      Signal.new(@func, @time_scale * f, @value_scale, @value_offset, @time_offset)
    end

    def slow(factor)
      fast(1.0 / factor.to_f)
    end

    # Shift later by amount cycles, folded into the time coefficients:
    # sampling at t must read the function at (t - amount).
    def late(amount)
      k = amount.to_f
      Signal.new(@func, @time_scale, @value_scale, @value_offset,
                 @time_offset - k * @time_scale)
    end

    def early(amount)
      late(-amount.to_f)
    end

    # Rescale the sampled value to min..max. Folds into the linear
    # coefficients: min + (offset + scale * f) * (max - min).
    def range(min, max)
      span = (max - min).to_f
      Signal.new(@func, @time_scale,
                 @value_scale * span, min + @value_offset * span, @time_offset)
    end

    def with_value(&block)
      source = self
      Signal.new { |t| block.call(source.sample(t)) }
    end
  end

  # Build a continuous pattern from a block of cycle position (Float).
  def self.signal(&func)
    Signal.new(&func)
  end

  # Rising ramp 0..1 each cycle.
  def self.saw
    signal { |t| t - t.floor }
  end

  # Falling ramp 1..0 each cycle.
  def self.isaw
    signal { |t| 1.0 - (t - t.floor) }
  end

  # Sine mapped to 0..1, starting at 0.5 rising.
  def self.sine
    signal { |t| 0.5 + 0.5 * Math.sin(TWO_PI * t) }
  end

  # Cosine mapped to 0..1.
  def self.cosine
    signal { |t| 0.5 + 0.5 * Math.cos(TWO_PI * t) }
  end

  # Triangle 0..1..0 each cycle.
  def self.tri
    signal do |t|
      phase = t - t.floor
      phase < 0.5 ? phase * 2.0 : 2.0 - phase * 2.0
    end
  end

  # Square: 0 for the first half cycle, 1 for the second.
  def self.square_signal
    signal { |t| (t - t.floor) < 0.5 ? 0.0 : 1.0 }
  end
end
