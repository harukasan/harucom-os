# cp: Copy a file
#
# Usage from IRB:
#   cp source.txt dest.txt
#   cp source.txt /path/to/dir/
#   cp -f source.txt existing.txt   (force overwrite)

require "option_parser"

force = false
opts = OptionParser.new
opts.banner = "Usage: cp [-f] <source> <target>"
opts.on("-f", "Force overwrite if target exists") { force = true }
opts.parse!(ARGV)

unless ARGV.size == 2
  puts "cp: expected 2 arguments, got #{ARGV.size}"
  exit 1
end

source = ARGV[0]
target = ARGV[1]

unless File.exist?(source)
  puts "cp: #{source}: No such file or directory"
  exit 1
end

if File.directory?(source)
  puts "cp: #{source}: Is a directory"
  exit 1
end

# If target is a directory, append source filename. Strip any trailing
# slash first so "dir/" and "dir" both produce "dir/name" rather than
# "dir//name".
target = target.chomp("/") if target.length > 1 && target.end_with?("/")
if File.directory?(target)
  name = source.split("/")[-1]
  target = "#{target}/#{name}"
end

if File.exist?(target) && !force
  puts "cp: #{target}: already exists (use -f to overwrite)"
  exit 1
end

begin
  File.open(source, "r") do |src|
    File.open(target, "w") do |dst|
      while chunk = src.read(512)
        dst.write(chunk)
      end
    end
  end
rescue => e
  puts "cp: #{e.message}"
end
