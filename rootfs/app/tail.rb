# tail: Display last lines of a file
#
# Usage from IRB:
#   tail file.rb
#   tail -n 20 file.rb
#   tail file1.rb file2.rb

require "option_parser"

lines = 10
opts = OptionParser.new
opts.banner = "Usage: tail [options] <file> [file ...]"
opts.on("-n NUM", "Number of lines (default: 10)") { |v| lines = v.to_i }
opts.parse!(ARGV)

if ARGV.empty?
  puts "tail: missing file operand"
  exit 1
end

multi = ARGV.size > 1

ARGV.each do |path|
  unless File.exist?(path)
    puts "tail: #{path}: No such file or directory"
    next
  end
  if File.directory?(path)
    puts "tail: #{path}: Is a directory"
    next
  end
  puts "==> #{path} <==" if multi
  begin
    # Read all lines into a ring buffer of size `lines`
    buf = []
    File.open(path, "r") do |f|
      while line = f.gets
        buf << line
        buf.shift if buf.size > lines
      end
    end
    buf.each { |line| print line }
  rescue => e
    puts "tail: #{path}: #{e.message}"
  end
end
