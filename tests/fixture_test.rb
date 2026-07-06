require "picotest"
require "johakyu/fixture"

# Johakyu fixture layer: attribute to absolute channel resolution,
# quantization, name tables, groups and spread. Runs against the DMX
# stub from tests/stubs.rb.
class FixtureTest < Picotest::Test
  def setup
    DMX.reset
    Johakyu.patch = Johakyu.default_patch
  end

  def dmx(name)
    Johakyu.dmx(name)
  end

  def test_patch_layout
    assert_equal 26, Johakyu.patch.max_channel
    assert_equal 6, dmx(:s1).channel(:dimmer)
    assert_equal 19, dmx(:s2).channel(:dimmer)
    assert_equal [:s1, :s2], Johakyu.patch.fixture_names
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

  def test_unknown_attribute_raises
    assert_raise(ArgumentError) { dmx(:s1).channel(:laser) }
  end

  def test_unknown_name_raises
    assert_raise(ArgumentError) { Johakyu.dmx(:nope) }
  end

  def test_overlapping_patch_raises
    patch = Johakyu::Patch.new
    patch.add(:a, Johakyu::SHEHDS_SPOT_80W_13CH, base: 1)
    assert_raise(ArgumentError) do
      patch.add(:b, Johakyu::SHEHDS_SPOT_80W_13CH, base: 13)
    end
  end

  def test_nested_groups_flatten
    patch = Johakyu::Patch.new
    patch.add(:a, Johakyu::SHEHDS_SPOT_80W_13CH, base: 1)
    patch.add(:b, Johakyu::SHEHDS_SPOT_80W_13CH, base: 14)
    patch.add(:c, Johakyu::SHEHDS_SPOT_80W_10CH, base: 100)
    patch.group(:pair, :a, :b)
    patch.group(:everything, :pair, :c)
    assert_equal 3, patch[:everything].members.length
    assert_equal 109, patch.max_channel
  end
end
