require "picotest"
require "console"

# Console behavior on the DVI text stub, including the dynamic grid that
# follows DVI::Text.set_resolution (the zoom feature).
class ConsoleTest < Picotest::Test
  def setup
    DVI::Text.set_resolution(640, 480)
    @console = Console.new
  end

  def test_dimensions_follow_dvi
    assert_equal 106, Console.cols
    assert_equal 37, Console.rows
  end

  def test_write_advances_cursor
    @console.write("abc")
    assert_equal 3, @console.col
    assert_equal 0, @console.row
  end

  def test_wide_char_advances_two_columns
    @console.write("あ")
    assert_equal 2, @console.col
  end

  def test_wrap_at_column_limit
    Console.cols.times { @console.write("x") }
    @console.write("y")
    assert_equal 1, @console.col
    assert_equal 1, @console.row
  end

  def test_newline_scrolls_at_bottom
    Console.rows.times { @console.write("\n") }
    assert_equal Console.rows - 1, @console.row
    assert_equal 0, @console.col
  end

  def test_scaled_dimensions
    DVI::Text.set_resolution(320, 240)
    assert_equal 53, Console.cols
    assert_equal 18, Console.rows
  end

  def test_wrap_follows_scaled_grid
    DVI::Text.set_resolution(320, 240)
    @console.reset
    53.times { @console.write("x") }
    @console.write("y")
    assert_equal 1, @console.col
    assert_equal 1, @console.row
  end

  def test_scroll_follows_scaled_grid
    DVI::Text.set_resolution(320, 240)
    @console.reset
    18.times { @console.write("\n") }
    assert_equal 17, @console.row
  end

  def test_reset_homes_cursor_and_drops_scrollback
    Console.rows.times { @console.write("\n") } # pushes a line into scrollback
    @console.scroll_back(5)
    assert @console.scroll_offset > 0
    DVI::Text.set_resolution(320, 240)
    @console.reset
    assert_equal 0, @console.col
    assert_equal 0, @console.row
    assert_equal 0, @console.scroll_offset
    @console.scroll_back(5) # scrollback dropped, stays in live view
    assert_equal 0, @console.scroll_offset
  end

  def test_set_resolution_rejects_unknown
    assert_raise(ArgumentError) do
      DVI::Text.set_resolution(800, 600)
    end
  end
end
