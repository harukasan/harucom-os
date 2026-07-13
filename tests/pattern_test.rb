require "picotest"
require "johakyu/pattern"
require "johakyu/signal"

# Johakyu pattern core semantics. Expectations were verified against
# asonas/strudel-rb with a host diff (research 04); these tests pin the
# behavior on the actual picoruby VM. hap_sigs comes from stubs.rb.
class PatternTest < Picotest::Test
  P = Johakyu::Pattern

  def test_pure_repeats_per_cycle
    assert_equal ["0/1..1/1|0/1..1/1|1", "1/1..2/1|1/1..2/1|1"],
                 hap_sigs(P.pure(1).query_arc(0, 2))
  end

  def test_pure_partial_query_is_not_onset
    haps = P.pure(1).query_arc(0.5, 1)
    assert_equal ["0/1..1/1|1/2..1/1|1"], hap_sigs(haps)
    assert_equal false, haps[0].has_onset?
  end

  def test_fastcat_divides_cycle
    assert_equal ["0/1..1/3|0/1..1/3|1", "1/3..2/3|1/3..2/3|2", "2/3..1/1|2/3..1/1|3"],
                 hap_sigs(P.fastcat(1, 2, 3).query_arc(0, 1))
  end

  def test_slowcat_one_item_per_cycle
    assert_equal ["0/1..1/1|0/1..1/1|1", "1/1..2/1|1/1..2/1|2", "2/1..3/1|2/1..3/1|1"],
                 hap_sigs(P.slowcat(1, 2).query_arc(0, 3))
  end

  def test_stack_unions
    assert_equal ["0/1..1/2|0/1..1/2|1", "1/2..1/1|1/2..1/1|2", "0/1..1/1|0/1..1/1|9"],
                 hap_sigs(P.stack(P.fastcat(1, 2), 9).query_arc(0, 1))
  end

  def test_euclid_3_8
    haps = P.euclid(3, 8).query_arc(0, 1)
    onsets = haps.map { |h| frac_s(h.whole.begin_time) }
    assert_equal ["0/1", "3/8", "3/4"], onsets
  end

  def test_fast_and_slow
    assert_equal ["0/1..1/4|0/1..1/4|1", "1/4..1/2|1/4..1/2|2",
                  "1/2..3/4|1/2..3/4|1", "3/4..1/1|3/4..1/1|2"],
                 hap_sigs(P.fastcat(1, 2).fast(2).query_arc(0, 1))
    assert_equal ["0/1..1/1|0/1..1/1|1", "1/1..2/1|1/1..2/1|2"],
                 hap_sigs(P.fastcat(1, 2).slow(2).query_arc(0, 2))
  end

  def test_rev_reverses_within_cycle
    assert_equal ["0/1..1/3|0/1..1/3|3", "1/3..2/3|1/3..2/3|2", "2/3..1/1|2/3..1/1|1"],
                 hap_sigs(P.fastcat(1, 2, 3).rev.query_arc(0, 1))
  end

  def test_every_applies_on_last_of_n
    pattern = P.fastcat(1, 2).every(2) { |p| p.rev }
    assert_equal ["0/1..1/2|0/1..1/2|1", "1/2..1/1|1/2..1/1|2",
                  "1/1..3/2|1/1..3/2|2", "3/2..2/1|3/2..2/1|1"],
                 hap_sigs(pattern.query_arc(0, 2))
  end

  def test_struct_takes_rhythm_from_bools
    haps = P.pure(5).struct(P.euclid(3, 8)).query_arc(0, 1)
    assert_equal 3, haps.length
    assert_equal 5, haps[0].value
  end

  def test_mask_filters_by_bools
    haps = P.fastcat(1, 2, 3, 4).mask(P.fastcat(true, false)).query_arc(0, 1)
    assert_equal ["0/1..1/4|0/1..1/4|1", "1/4..1/2|1/4..1/2|2"], hap_sigs(haps)
  end

  def test_segment_samples_signal
    haps = Johakyu.saw.segment(4).query_arc(0, 1)
    assert_equal 4, haps.length
    assert_equal "0/1..1/4", "#{frac_s(haps[0].whole.begin_time)}..#{frac_s(haps[0].whole.end_time)}"
    # saw samples at segment midpoints: 1/8, 3/8, 5/8, 7/8
    assert_equal true, (haps[0].value - 0.125).abs < 1e-9
    assert_equal true, (haps[3].value - 0.875).abs < 1e-9
  end

  def test_range_rescales
    haps = P.fastcat(0.0, 0.5, 1.0).range(10, 20).query_arc(0, 1)
    assert_equal [10.0, 15.0, 20.0], haps.map { |h| h.value }
  end

  def test_arithmetic
    haps = P.fastcat(0, 2, 4).add(P.pure(10)).query_arc(0, 1)
    assert_equal [10, 12, 14], haps.map { |h| h.value }
  end

  def test_degrade_by_is_deterministic
    survivors = P.fastcat(1, 2, 3, 4, 5, 6, 7, 8).degrade_by(0.5).query_arc(0, 1)
    again = P.fastcat(1, 2, 3, 4, 5, 6, 7, 8).degrade_by(0.5).query_arc(0, 1)
    assert_equal hap_sigs(survivors), hap_sigs(again)
    assert_equal true, survivors.length < 8
  end

  def test_windowed_queries_fire_onsets_once
    pattern = P.fastcat(1, 2, 3, 4)
    onsets = []
    last = Johakyu::Fraction.new(0)
    20.times do
      horizon = last + Johakyu::Fraction.new(13, 100)
      pattern.query(Johakyu::TimeSpan.new(last, horizon)).each do |h|
        onsets << frac_s(h.whole.begin_time) if h.has_onset?
      end
      last = horizon
    end
    assert_equal ["0/1", "1/4", "1/2", "3/4", "1/1", "5/4", "3/2", "7/4", "2/1", "9/4"],
                 onsets[0, 10]
  end

  def test_fraction_exactness
    third = Johakyu::Fraction.new(1, 3)
    sum = third + third + third
    assert_equal 1, sum.num
    assert_equal 1, sum.den
    assert_equal true, Johakyu::Fraction.new(2, 6) == third
  end

  def test_continuous_detection
    assert_equal true, Johakyu.sine.continuous?
    assert_equal true, Johakyu.sine.range(0.2, 0.8).slow(8).continuous?
    assert_equal false, Johakyu.saw.segment(4).continuous?
    assert_equal false, P.pure(1).continuous?
    assert_equal false, P.silence.continuous?
    assert_equal false, P.euclid(3, 8).continuous?
  end

  def test_signal_transform_chain_keeps_fast_path
    signal = Johakyu.sine.range(0.2, 0.8).slow(8)
    assert_equal true, signal.is_a?(Johakyu::Signal)
    # slow(8) at position 2.0 samples sine at 0.25 (its peak): 0.8
    value = signal.sample(2.0)
    assert_equal true, (value - 0.8).abs < 1e-9
    # the fast path agrees with the query path
    queried = signal.query_arc(2.0, 2.0 + 1.0 / 3840)[0].value
    assert_equal true, (queried - value).abs < 0.001
  end

  def test_generic_sample_falls_back_to_query
    assert_equal 2, P.fastcat(1, 2).sample(0.5)
    assert_equal true, P.silence.sample(0.25).nil?
  end

  def test_late_shifts_onsets
    assert_equal ["1/4..3/4|1/4..3/4|\"a\"", "3/4..5/4|3/4..5/4|\"b\""],
                 hap_sigs(P.fastcat("a", "b").late(0.25).query_arc(0.25, 1.25))
  end

  def test_late_wraps_previous_cycle_tail
    haps = P.fastcat("a", "b").late(0.25).query_arc(0, 0.25)
    # the head of the cycle shows the previous cycle's "b" tail
    # (whole shifted from cycle -1) without an onset
    assert_equal ["-1/4..1/4|0/1..1/4|\"b\""], hap_sigs(haps)
    assert_equal false, haps[0].has_onset?
  end

  def test_early_is_the_inverse_of_late
    base = P.fastcat("a", "b")
    assert_equal hap_sigs(base.query_arc(0, 1)),
                 hap_sigs(base.late(0.25).early(0.25).query_arc(0, 1))
  end

  def test_signal_late_folds_into_coefficients
    shifted = Johakyu.saw.late(0.25)
    assert_equal true, shifted.is_a?(Johakyu::Signal)
    assert_equal true, (shifted.sample(0.5) - 0.25).abs < 1e-9
    # late then fast keeps the shift aligned to the original timeline
    combo = Johakyu.saw.slow(2).late(0.5)
    assert_equal true, (combo.sample(0.5) - Johakyu.saw.slow(2).sample(0.0)).abs < 1e-9
  end

  def test_with_control_samples_at_onsets
    left = P.fastcat("bd", "sn").fmap { |v| { s: v } }
    haps = left.with_control(:pan, Johakyu.saw).query_arc(0, 1)
    assert_equal({ s: "bd", pan: 0.0 }, haps[0].value)
    assert_equal({ s: "sn", pan: 0.5 }, haps[1].value)
  end

  def test_with_control_constant_and_pattern
    left = P.pure("bd").fmap { |v| { s: v } }
    assert_equal({ s: "bd", color: "red" },
                 left.with_control(:color, "red").query_arc(0, 1)[0].value)
    colors = P.slowcat("red", "blue")
    assert_equal "blue",
                 left.with_control(:color, colors).query_arc(1, 2)[0].value[:color]
  end

  def test_with_control_skips_silent_control
    left = P.pure("bd").fmap { |v| { s: v } }
    haps = left.with_control(:color, P.silence).query_arc(0, 1)
    assert_equal({ s: "bd" }, haps[0].value)
  end
end
