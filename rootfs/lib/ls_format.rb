# Long-format rows for ls.
#
# This lives in lib rather than in the app because an app runs in a Sandbox
# whose target is the shared object space, so definitions in the script outlive
# the run and pile up on Object. Keeping it here also lets the host tests reach
# it, which matters for the parts the browser build cannot exercise.
#
# Neither filesystem behind ls carries POSIX permission bits, so a row shows what
# both can answer: type, size, time and name. There is no permission column
# because mode_str has no implementation to read one from.
module LsFormat
  # Spaced to sit over the row below: the size label ends where the
  # right-aligned size ends, datetime starts where the stamp starts, and name
  # starts after a stamp of the width Time#to_s prints on the board. This names
  # the columns the rows below print, unlike Littlefs::Stat::LABEL, which was
  # written for a row that starts at the size.
  HEADER = "T     size datetime                  name"

  # A VFS build carries File::Stat, a build without one does not.
  HAS_STAT = defined?(File::Stat) ? true : false

  # `directory` is passed in because the caller has already established it, and
  # on flash each extra stat is another read.
  def self.row(path, name, directory)
    size, time = measure(path)
    format_row(size, time, name, directory)
  end

  # Split from row so the header test can pin the columns without a filesystem,
  # rather than writing the widths out a second time to compare against.
  def self.format_row(size, time, name, directory)
    "#{directory ? "d" : "-"} #{size.to_s.rjust(8)} #{time_string(time)} #{name}"
  end

  # An entry that cannot be measured keeps its columns, so the listing still
  # reads down and the message cannot be mistaken for part of the name.
  def self.error_row(name, message)
    "? #{"-".rjust(8)} - #{name} (#{message})"
  end

  # Size and time sit on opposite sides of the two filesystems: a VFS carries
  # them on File::Stat, while the posix File answers both only through an open
  # handle.
  def self.measure(path)
    if HAS_STAT
      stat = File::Stat.new(path)
      return [stat.size, stat.mtime]
    end
    # One handle answers both, rather than a stat plus an open.
    File.open(path) { |f| [f.size, f.mtime] }
  end

  # A board with no clock stamps everything at the epoch, so every row would
  # carry the same 1970 date. Say the time is unset instead of repeating it.
  def self.time_string(time)
    time.to_i.zero? ? "-" : time.to_s
  end
end
