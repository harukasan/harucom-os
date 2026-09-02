require "ls_format"

# The browser build cannot reach every branch here: its MEMFS stamps real
# mtimes, so the unset-clock case never runs there. These cover it on the host.
class LsFormatTest < Picotest::Test
  # A stand-in for a Time: the code only asks it these two questions.
  class FakeTime
    def initialize(seconds, text)
      @seconds = seconds
      @text = text
    end

    def to_i = @seconds
    def to_s = @text
  end

  def test_time_str_shows_the_stamp_when_the_clock_is_set
    time = FakeTime.new(1_756_800_000, "2026-09-02 12:00:00 +0900")
    assert_equal "2026-09-02 12:00:00 +0900", LsFormat.time_str(time)
  end

  # A board with no clock stamps every file at the epoch, so printing the date
  # would repeat 1970 down the whole listing and say nothing.
  def test_time_str_reports_an_unset_clock_as_a_dash
    time = FakeTime.new(0, "1970-01-01 00:00:00 +0000")
    assert_equal "-", LsFormat.time_str(time)
  end

  # The header has to sit over the columns the rows print, and the rows are
  # built from fixed widths, so the two can drift apart silently.
  def test_header_sits_over_the_columns_the_rows_print
    header = LsFormat::HEADER
    size = "12"
    row = "- #{size.rjust(8)} 2026-09-02 12:00:00 +0900 name"
    # The size is right-aligned, so both labels are pinned to where it ends.
    size_end = row.index(size) + size.length
    assert_equal size_end, header.index("size") + "size".length
    assert_equal size_end + 1, header.index("datetime")
  end
end
