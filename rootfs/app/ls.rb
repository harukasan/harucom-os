# ls: List directory contents
#
# Usage from IRB:
#   ls
#   ls /app
#   ls -l

require "option_parser"
require "ls_format"

options = {}
opts = OptionParser.new
opts.banner = "Usage: ls [options] [path]"
opts.on("-l", "Long format") { options[:l] = true }
opts.parse!(ARGV)

path = ARGV[0] || "."

# If path is a file, show just that file
if File.exist?(path) && !File.directory?(path)
  if options[:l]
    puts LsFormat.row(path, path, false) # the guard above already settled this
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
      # The header names these columns, not the ones LittleFS::Stat::LABEL was
      # written for: that one starts at size and this row starts at the type.
      puts "#{Console::CYAN}#{LsFormat::HEADER}#{Console::RESET}"
      while entry = dir.read
        full = "#{path}/#{entry}"
        directory = File.directory?(full)
        name = directory ? "#{Console::BLUE}#{entry}#{Console::RESET}" : entry
        # One bad entry should cost its own row, not the rest of the listing.
        begin
          puts LsFormat.row(full, name, directory)
        rescue => e
          puts "#{name} (#{e.message})"
        end
      end
    else
      while entry = dir.read
        # File.directory? rather than File::Stat: the plain listing needs only
        # this one predicate, and every platform has it.
        if File.directory?("#{path}/#{entry}")
          puts "#{Console::BLUE}#{entry}#{Console::RESET}"
        else
          puts entry
        end
      end
    end
  end
rescue => e
  puts "ls: #{path}: #{e.message}"
end
