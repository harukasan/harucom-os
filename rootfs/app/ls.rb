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
# time. File::Stat is deliberately not used, because it comes from the
# filesystem gem and a platform without a VFS does not have it.
def entry_type(path)
  File.directory?(path) ? "d" : "-"
end

# File.mtime exists where a VFS provides it. Elsewhere the instance method does,
# and the block form closes the descriptor either way.
def entry_mtime(path)
  if File.respond_to?(:mtime)
    File.mtime(path)
  else
    File.open(path) { |f| f.mtime }
  end
end

def long_entry(path, name)
  "#{entry_type(path)} #{File.size(path).to_s.rjust(8)} #{entry_mtime(path)} #{name}"
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
