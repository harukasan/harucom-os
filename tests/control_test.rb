require "picotest"
require "johakyu/control"

# The all-pattern control surface: statements are Patterns of control
# maps, one query feeding both the sound and light sinks.
class ControlTest < Picotest::Test
  def setup
    Johakyu.patch = johakyu_test_patch
  end

  # Pins the generated statement sugar on every layer that builds
  # control maps: the bare statement, the target builder, and the
  # pattern chain must all wrap values under their own key.
  def test_every_light_control_builds_its_key
    Johakyu::LIGHT_CONTROLS.each do |key|
      bare = onsets(Johakyu.send(key, "1"))
      assert_equal({ key => "1" }, bare[0].value)
      targeted = onsets(Johakyu.dmx_builder(:s1).send(key, "1"))
      assert_equal "1", targeted[0].value[key]
      assert_equal 6, targeted[0].value[:target].channel(:dimmer)
      chained = onsets(Johakyu.sound("bd").send(key, "0.5"))
      assert_equal "0.5", chained[0].value[key]
    end
  end

  def onsets(pattern, from = 0, to = 1)
    haps = pattern.query_arc(from, to)
    result = []
    i = 0
    while i < haps.length
      result << haps[i] if haps[i].has_onset?
      i += 1
    end
    result
  end

  def test_sound_wraps_values_into_control_maps
    haps = onsets(Johakyu.sound("bd sn"))
    assert_equal({ s: "bd" }, haps[0].value)
    assert_equal({ s: "sn" }, haps[1].value)
  end

  def test_light_constructor_wraps_values
    haps = onsets(Johakyu.dimmer("1 0"))
    assert_equal({ dimmer: "1" }, haps[0].value)
    assert_equal({ dimmer: "0" }, haps[1].value)
  end

  def test_bare_signal_source_is_segmented
    pattern = Johakyu.pan(Johakyu.saw)
    assert_equal false, pattern.continuous?
    haps = onsets(pattern)
    assert_equal Johakyu::SEGMENT_DEFAULT, haps.length
    # segment samples at step midpoints: the first of 16 steps reads
    # saw at 1/32
    assert_equal({ pan: 0.03125 }, haps[0].value)
  end

  def test_on_resolves_target_at_build_time
    haps = onsets(Johakyu.dimmer("1").on(:s1))
    target = haps[0].value[:target]
    assert_equal :s1, target.name
    assert_raise(ArgumentError) do
      Johakyu.dimmer("1").on(:nonexistent)
    end
  end

  def test_dmx_builder_is_on_sugar
    haps = onsets(Johakyu.dmx_builder(:s2).dimmer("1 0"))
    assert_equal "1", haps[0].value[:dimmer]
    assert_equal :s2, haps[0].value[:target].name
  end

  def test_chained_control_uses_structure_from_left
    pattern = Johakyu.dimmer("1 0").color("<red blue>")
    first_cycle = onsets(pattern)
    assert_equal 2, first_cycle.length
    assert_equal "red", first_cycle[0].value[:color]
    assert_equal "red", first_cycle[1].value[:color]
    second_cycle = onsets(pattern, 1, 2)
    assert_equal "blue", second_cycle[0].value[:color]
  end

  def test_sound_with_light_control_rides_the_beat
    haps = onsets(Johakyu.sound("bd*4").color("<red blue>"))
    assert_equal 4, haps.length
    assert_equal "bd", haps[0].value[:s]
    assert_equal "red", haps[0].value[:color]
  end

  def test_chained_signal_control_samples_at_onsets
    haps = onsets(Johakyu.sound("bd bd").pan(Johakyu.saw))
    assert_equal 0.0, haps[0].value[:pan]
    assert_equal 0.5, haps[1].value[:pan]
  end

  def test_spread_duplicates_across_group_members
    haps = onsets(Johakyu.dimmer("1").spread(0.5, on: :all), 0, 2)
    # two members: s1 at cycle starts, s2 shifted late by 0.5
    starts = haps.map { |h| [h.value[:target].name, h.whole.begin_time.to_f] }
    assert_equal true, starts.include?([:s1, 0.0])
    assert_equal true, starts.include?([:s2, 0.5])
    assert_equal true, starts.include?([:s1, 1.0])
    assert_equal true, starts.include?([:s2, 1.5])
  end
end
