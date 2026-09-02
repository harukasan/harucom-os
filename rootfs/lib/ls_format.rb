# Long-format rows for ls.
#
# This lives in lib rather than in the app because an app runs in a Sandbox
# whose target is the shared object space, so a module defined in the script
# would be created fresh on every run. Keeping it here also lets the host tests
# reach it, which matters for the parts the browser build cannot exercise.
#
# Neither filesystem behind ls carries POSIX permission bits, so a row shows what
# both can answer: type, size, time and name. There is no permission column
# because mode_str has no implementation to read one from.
module LsFormat
  # Spaced to sit over the row below: the size label ends where the
  # right-aligned size ends, and datetime starts where the stamp starts.
  HEADER = "T     size datetime                  name"

  # A VFS build carries File::Stat, a build without one does not.
  HAS_STAT = defined?(File::Stat) ? true : false

  # `directory` is passed in because the caller has already established it, and
  # on flash each extra stat is another read.
  def self.row(path, name, directory)
    size, time = measure(path)
    "#{directory ? "d" : "-"} #{size.to_s.rjust(8)} #{time_str(time)} #{name}"
  end

  # Size and time sit on opposite sides of the two filesystems: a VFS carries
  # them on File::Stat, while the posix File answers both only through an open
  # handle. The stat is asked whether it has them rather than assumed to, because
  # a class being present says nothing about what it implements. respond_to? is
  # core, where method_defined? would pull in mruby-metaprog.
  def self.measure(path)
    if HAS_STAT
      stat = File::Stat.new(path)
      return [stat.size, stat.mtime] if stat.respond_to?(:size) && stat.respond_to?(:mtime)
    end
    # One handle answers both, rather than a stat plus an open.
    File.open(path) { |f| [f.size, f.mtime] }
  end

  # A board with no clock stamps everything at the epoch, so every row would
  # carry the same 1970 date. Say the time is unset instead of repeating it.
  def self.time_str(time)
    time.to_i.zero? ? "-" : time.to_s
  end
end
