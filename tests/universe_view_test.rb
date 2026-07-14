require "picotest"

# The universe view sizes itself from the running rig: clock row only
# without a patch, fixture and grid rows (capped) with one. The grid
# math reads the real Console, which delegates to the DVI stub
# (106x37).
require "console"
require "johakyu/universe_view"

class UniverseViewTest < Picotest::Test
  def view
    Johakyu::UniverseView.new(nil, top: 0)
  end

  def test_no_rig_shows_the_clock_row_only
    Johakyu.patch = Johakyu::Patch.new
    assert_equal 1, view.rows
  end

  def test_rig_adds_fixture_grid_and_separator_rows
    Johakyu.patch = johakyu_test_patch
    # clock + two fixtures + two grid rows (26 channels at 13 cells
    # per row) + separator
    assert_equal 6, view.rows
  end

  def test_large_rig_is_capped
    personality = Johakyu.personality(JOHAKYU_TEST_FIXTURE, "13ch")
    patch = Johakyu::Patch.new
    patch.add(:far, personality, base: 500)
    Johakyu.patch = patch
    # 512 channels would need 40 grid rows; the cap keeps the view to
    # clock + one fixture + four grid rows + separator
    assert_equal 7, view.rows
  end

  def test_repatch_follows_a_rig_swap
    Johakyu.patch = Johakyu::Patch.new
    v = view
    assert_equal 1, v.rows
    Johakyu.patch = johakyu_test_patch
    v.repatch
    assert_equal 6, v.rows
  end
end
