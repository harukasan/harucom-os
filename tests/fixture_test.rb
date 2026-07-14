require "picotest"
require "johakyu/fixture"

# Johakyu fixture layer: OFL personality conversion, attribute to
# absolute channel resolution, quantization, name tables, groups and
# spread. Runs against the DMX stub from tests/stubs.rb; the values
# pin the bench-verified SHEHDS chart (M0-M3), so they also guard the
# from_ofl conversion of the shipped definition.
class FixtureTest < Picotest::Test
  def setup
    DMX.reset
    Johakyu.patch = johakyu_test_patch
  end

  def dmx(name)
    Johakyu.dmx(name)
  end

  def personality_13ch
    Johakyu.personality(JOHAKYU_TEST_FIXTURE, "13ch")
  end

  def test_patch_layout
    assert_equal 26, Johakyu.patch.max_channel
    assert_equal 6, dmx(:s1).channel(:dimmer)
    assert_equal 19, dmx(:s2).channel(:dimmer)
    assert_equal [:s1, :s2], Johakyu.patch.fixture_names
  end

  def test_from_ofl_channel_map
    p13 = personality_13ch
    assert_equal 13, p13.channels
    assert_equal 1, p13.offset(:pan)
    assert_equal 2, p13.offset(:pan_fine)
    assert_equal 3, p13.offset(:tilt)
    assert_equal 4, p13.offset(:tilt_fine)
    assert_equal 5, p13.offset(:speed)
    assert_equal 6, p13.offset(:dimmer)
    assert_equal 7, p13.offset(:strobe)
    assert_equal 8, p13.offset(:color)
    assert_equal 9, p13.offset(:gobo)
    assert_equal 10, p13.offset(:focus)
    assert_equal 11, p13.offset(:prism)
    assert_equal 13, p13.offset(:function)
  end

  def test_from_ofl_mode_selection
    p10 = Johakyu.personality(JOHAKYU_TEST_FIXTURE, "10ch")
    assert_equal 10, p10.channels
    assert_equal 3, p10.offset(:dimmer)
    assert_equal nil, p10.offset(:pan_fine)
    assert_raise(ArgumentError) do
      fixture = DMX::Fixture.read(JOHAKYU_TEST_FIXTURE)
      Johakyu::Personality.from_ofl(fixture, "31ch")
    end
  end

  def test_from_ofl_effect_table
    table = personality_13ch.table(:function)
    assert_equal 175, table[:full_auto]
    assert_equal 225, table[:sound_control]
    assert_equal 253, table[:reset]
  end

  def test_from_ofl_strobe_range
    assert_equal [16, 251], personality_13ch.range(:strobe)
  end

  def test_loader_rejects_missing_definition
    assert_raise(ArgumentError) do
      Johakyu.personality("rootfs/data/dmx/fixtures/no_such_light.json")
    end
  end

  def test_preload_fixtures_warms_the_cache
    assert_equal 1, Johakyu.preload_fixtures("rootfs/data/dmx/fixtures")
    assert_equal 13, Johakyu.personality(JOHAKYU_TEST_FIXTURE, "13ch").channels
  end

  def test_pan_writes_16bit_pair
    dmx(:s1).pan(0.5)
    assert_equal 128, DMX.get(1)
    assert_equal 0, DMX.get(2)
  end

  def test_second_fixture_resolves_from_base
    dmx(:s2).pan(0.5)
    assert_equal 128, DMX.get(14)
    assert_equal 0, DMX.get(1)
  end

  def test_normalization_and_clamp
    dmx(:s1).dimmer(1)
    assert_equal 255, DMX.get(6)
    dmx(:s1).dimmer(-0.5)
    assert_equal 0, DMX.get(6)
    dmx(:s1).dimmer(1.5)
    assert_equal 255, DMX.get(6)
  end

  def test_strobe_range
    dmx(:s1).strobe(1.0)
    assert_equal 251, DMX.get(7)
    dmx(:s1).strobe(0.5)
    assert_equal 134, DMX.get(7)
    dmx(:s1).strobe(0)
    assert_equal 0, DMX.get(7)
  end

  def test_name_tables
    dmx(:s1).color(:red)
    assert_equal 12, DMX.get(8)
    dmx(:s1).color("blue")
    assert_equal 28, DMX.get(8)
    dmx(:s1).gobo(:open)
    assert_equal 4, DMX.get(9)
    dmx(:s1).prism(:rotate)
    assert_equal 192, DMX.get(11)
  end

  def test_group_broadcast
    dmx(:all).dimmer(1.0)
    assert_equal 255, DMX.get(6)
    assert_equal 255, DMX.get(19)
  end

  def test_spread_offsets_members
    dmx(:all).spread(0.5).pan(0.25)
    assert_equal 64, DMX.get(1)
    assert_equal 191, DMX.get(14)
  end

  def test_spread_broadcasts_names_unchanged
    dmx(:all).spread(1.0).color(:red)
    assert_equal 12, DMX.get(8)
    assert_equal 12, DMX.get(21)
  end

  def test_raw_escape_hatch
    dmx(:s1).raw(:pan, 200)
    assert_equal 200, DMX.get(1)
  end

  def test_chaining
    dmx(:s1).pan(0.5).tilt(0.5).dimmer(1.0)
    assert_equal 128, DMX.get(1)
    assert_equal 128, DMX.get(3)
    assert_equal 255, DMX.get(6)
  end

  # Pins the generated attribute sugar: every LIGHT_CONTROLS entry has
  # its method and each captures its own attribute (a shared closure
  # would send them all to one channel).
  def test_every_attribute_writes_its_own_channel
    fixture = dmx(:s1)
    Johakyu::LIGHT_CONTROLS.each do |attribute|
      DMX.reset
      fixture.send(attribute, 1.0)
      expected = attribute == :strobe ? 251 : 255
      assert_equal expected, DMX.get(fixture.channel(attribute))
    end
  end

  def test_unknown_attribute_raises
    assert_raise(ArgumentError) { dmx(:s1).channel(:laser) }
  end

  def test_unknown_name_raises
    assert_raise(ArgumentError) { Johakyu.dmx(:nope) }
  end

  def test_overlapping_patch_raises
    patch = Johakyu::Patch.new
    patch.add(:a, personality_13ch, base: 1)
    assert_raise(ArgumentError) do
      patch.add(:b, personality_13ch, base: 13)
    end
  end

  def test_nested_groups_flatten
    patch = Johakyu::Patch.new
    patch.add(:a, personality_13ch, base: 1)
    patch.add(:b, personality_13ch, base: 14)
    patch.add(:c, Johakyu.personality(JOHAKYU_TEST_FIXTURE, "10ch"), base: 100)
    patch.group(:pair, :a, :b)
    patch.group(:everything, :pair, :c)
    assert_equal 3, patch[:everything].members.length
    assert_equal 109, patch.max_channel
  end
end
