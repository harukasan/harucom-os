# mkdir: Create a directory
#
# Usage from IRB:
#   mkdir dirname
#   mkdir /path/to/dirname

require "option_parser"

opts = OptionParser.new
opts.banner = "Usage: mkdir <directory>"
opts.parse!(ARGV)

unless ARGV[0]
  puts "mkdir: missing operand"
  exit 1
end

path = ARGV[0]

if Dir.exist?(path)
  puts "mkdir: #{path}: already exists"
  exit 1
end

begin
  Dir.mkdir(path)
rescue => e
  puts "mkdir: #{path}: #{e.message}"
end
