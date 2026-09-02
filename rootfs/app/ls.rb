# ls: List directory contents
#
# Usage from IRB:
#   ls
#   ls /app
#   ls -l

require "option_parser"

options = {}
opts = OptionParser.new
opts.banner = "Usage: ls [options] [path]"
opts.on("-l", "Long format") { options[:l] = true }
opts.parse!(ARGV)

# Neither filesystem behind this carries POSIX permission bits, so the long
# format shows what both can answer: the type, the size and the modification
# time. There is no permission column, because mode_str has no implementation
# to read one from.
def entry_type(path)
  File.directory?(path) ? "d" : "-"
end

# Size and time come from opposite places on the two filesystems: a VFS puts
# them on File::Stat and leaves File without them, while the posix File carries
# File.size and answers mtime only through an open handle. File.directory? above
# is the one both agree on.
def entry_stat(path)
  return File::Stat.new(path) if defined?(File::Stat)
  nil
end

def entry_size(path, stat)
  stat ? stat.size : File.size(path)
end

def entry_mtime(path, stat)
  stat ? stat.mtime : File.open(path) { |f| f.mtime } # block form closes the fd
end

# A board with no clock stamps everything at the epoch, so every row would carry
# the same 1970 date. Show that the time is unset instead of repeating it.
def entry_time_str(path, stat)
  time = entry_mtime(path, stat)
  time.to_i.zero? ? "-" : time.to_s
end

def long_entry(path, name)
  stat = entry_stat(path)
  size = entry_size(path, stat).to_s.rjust(8)
  "#{entry_type(path)} #{size} #{entry_time_str(path, stat)} #{name}"
end

path = ARGV[0] || "."

# If path is a file, show just that file
if File.exist?(path) && !File.directory?(path)
  if options[:l]
    puts long_entry(path, path)
  else
    puts path
  end
  exit
end

unless Dir.exist?(path)
  puts "ls: #{path}: No such file or directory"
  exit 1
end

begin
  Dir.open(path) do |dir|
    if options[:l]
      begin
        puts "\e[36m#{Littlefs::Stat::LABEL}\e[0m"
      rescue NameError
        # Not a LittleFS filesystem
      end
      while entry = dir.read
        full = "#{path}/#{entry}"
        name = File.directory?(full) ? "\e[34m#{entry}\e[0m" : entry
        puts long_entry(full, name)
      end
    else
      while entry = dir.read
        # File.directory? rather than File::Stat: the plain listing only needs
        # this one predicate, and File::Stat comes from the filesystem gem, which
        # a platform without a VFS does not have. Line 19 already uses this form.
        if File.directory?("#{path}/#{entry}")
          puts "\e[34m#{entry}\e[0m"
        else
          puts entry
        end
      end
    end
  end
rescue => e
  puts "ls: #{path}: #{e.message}"
end
