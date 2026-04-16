# rmdir: Remove an empty directory
#
# Usage from IRB:
#   rmdir dirname

require "option_parser"

opts = OptionParser.new
opts.banner = "Usage: rmdir <directory>"
opts.parse!(ARGV)

unless ARGV[0]
  puts "rmdir: missing operand"
  exit 1
end

path = ARGV[0]

unless Dir.exist?(path)
  puts "rmdir: #{path}: No such directory"
  exit 1
end

unless Dir.empty?(path)
  puts "rmdir: #{path}: Directory not empty"
  exit 1
end

begin
  Dir.unlink(path)
rescue => e
  puts "rmdir: #{path}: #{e.message}"
end
