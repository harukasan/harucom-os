# touch: Create an empty file
#
# Usage from IRB:
#   touch file.txt

require "option_parser"

opts = OptionParser.new
opts.banner = "Usage: touch <file>"
opts.parse!(ARGV)

unless ARGV[0]
  puts "touch: missing operand"
  exit 1
end

path = ARGV[0]

if File.exist?(path)
  exit
end

begin
  File.open(path, "w") { |f| }
rescue => e
  puts "touch: #{path}: #{e.message}"
end
