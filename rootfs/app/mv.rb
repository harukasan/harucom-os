# mv: Move or rename a file
#
# Usage from IRB:
#   mv old_name.txt new_name.txt
#   mv file.txt /path/to/dir/

require "option_parser"

opts = OptionParser.new
opts.banner = "Usage: mv <source> <target>"
opts.parse!(ARGV)

unless ARGV.size == 2
  puts "mv: expected 2 arguments, got #{ARGV.size}"
  exit 1
end

source = ARGV[0]
target = ARGV[1]

unless File.exist?(source)
  puts "mv: #{source}: No such file or directory"
  exit 1
end

# If target is a directory, append source filename
if File.directory?(target)
  name = source.split("/")[-1]
  target = "#{target}/#{name}"
end

begin
  File.rename(source, target)
rescue => e
  puts "mv: #{e.message}"
end
