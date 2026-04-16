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

path = ARGV[0] || "."

# If path is a file, show just that file
if File.exist?(path) && !File.directory?(path)
  if options[:l]
    stat = File::Stat.new(path)
    puts "#{stat.mode_str} #{stat.size.to_s.rjust(8)} #{stat.mtime} #{path}"
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
        puts "\e[36m#{FAT::Stat::LABEL}\e[0m"
      rescue NameError
        # Not a FAT filesystem
      end
      while entry = dir.read
        stat = File::Stat.new("#{path}/#{entry}")
        name = stat.directory? ? "\e[34m#{entry}\e[0m" : entry
        puts "#{stat.mode_str} #{stat.size.to_s.rjust(8)} #{stat.mtime} #{name}"
      end
    else
      while entry = dir.read
        begin
          if File::Stat.new("#{path}/#{entry}").directory?
            puts "\e[34m#{entry}\e[0m"
          else
            puts entry
          end
        rescue
          puts entry
        end
      end
    end
  end
rescue => e
  puts "ls: #{path}: #{e.message}"
end
