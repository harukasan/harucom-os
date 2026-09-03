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

  # The board prints this width, and HEADER's name column is spaced for it.
  STAMP = "2026-09-02 12:00:00 +0900"

  def test_time_string_shows_the_stamp_when_the_clock_is_set
    assert_equal STAMP, LsFormat.time_string(FakeTime.new(1_756_800_000, STAMP))
  end

  # A board with no clock stamps every file at the epoch, so printing the date
  # would repeat 1970 down the whole listing and say nothing.
  def test_time_string_reports_an_unset_clock_as_a_dash
    assert_equal "-", LsFormat.time_string(FakeTime.new(0, "1970-01-01 00:00:00 +0000"))
  end

  # The header has to sit over the columns the rows print, and the two are
  # written out separately, so they can drift apart silently. Going through
  # format_row is the point: comparing against a hand-built row would only
  # compare the test's copy of the widths with itself.
  def test_header_sits_over_the_columns_the_rows_print
    header = LsFormat::HEADER
    row = LsFormat.format_row(12, FakeTime.new(1_756_800_000, STAMP), "name", false)
    # The size is right-aligned, so both labels are pinned to where it ends.
    assert_equal header.index("size") + 4, row.index("12") + 2
    assert_equal header.index("datetime"), row.index(STAMP)
    assert_equal header.index("name"), row.index("name")
  end

  def test_format_row_marks_a_directory_with_d_and_a_file_with_a_dash
    time = FakeTime.new(1_756_800_000, STAMP)
    assert_equal "d", LsFormat.format_row(0, time, "app", true)[0, 1]
    assert_equal "-", LsFormat.format_row(0, time, "system.rb", false)[0, 1]
  end

  # An entry that cannot be measured still has to read down the listing, and
  # the message must not look like part of the name.
  def test_error_row_keeps_the_columns_of_a_normal_row
    row = LsFormat.error_row("gone", "No such file or directory")
    assert_equal "?", row[0, 1]
    assert_equal LsFormat::HEADER.index("size") + 4, row.index("-", 2) + 1
    assert_equal LsFormat::HEADER.index("datetime"), row.index("- gone")
  end

  # measure is why this moved to lib. The host has no File::Stat, so this is the
  # same branch the browser takes, against a real file rather than a stub.
  def test_row_reads_the_size_and_the_time_off_the_filesystem
    path = "rootfs/lib/ls_format.rb"
    size = File.open(path) { |f| f.size }
    row = LsFormat.row(path, "ls_format.rb", false)
    assert_equal "- #{size.to_s.rjust(8)} ", row[0, 11]
    assert_equal true, row.end_with?(" ls_format.rb")
  end
end
