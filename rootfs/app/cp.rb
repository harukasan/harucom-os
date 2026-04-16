# cp: Copy a file
#
# Usage from IRB:
#   cp source.txt dest.txt
#   cp source.txt /path/to/dir/

require "option_parser"

opts = OptionParser.new
opts.banner = "Usage: cp <source> <target>"
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

# If target is a directory, append source filename
if File.directory?(target)
  name = source.split("/")[-1]
  target = "#{target}/#{name}"
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
