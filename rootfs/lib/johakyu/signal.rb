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

require "johakyu/pattern"

module Johakyu
  TWO_PI = 6.283185307179586

  # Build a continuous pattern from a block of cycle position (Float).
  def self.signal(&func)
    Pattern.new do |span|
      [Hap.new(nil, span, func.call(span.midpoint.to_f))]
    end
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
