# head: Display first lines of a file
#
# Usage from IRB:
#   head file.rb
#   head -n 20 file.rb
#   head file1.rb file2.rb

require "option_parser"

lines = 10
opts = OptionParser.new
opts.banner = "Usage: head [options] <file> [file ...]"
opts.on("-n NUM", "Number of lines (default: 10)") { |v| lines = v.to_i }
opts.parse!(ARGV)

if ARGV.empty?
  puts "head: missing file operand"
  exit 1
end

multi = ARGV.size > 1
had_error = false

ARGV.each do |path|
  unless File.exist?(path)
    puts "head: #{path}: No such file or directory"
    had_error = true
    next
  end
  if File.directory?(path)
    puts "head: #{path}: Is a directory"
    had_error = true
    next
  end
  puts "==> #{path} <==" if multi
  begin
    File.open(path, "r") do |f|
      count = 0
      while count < lines && (line = f.gets)
        print line
        count += 1
      end
    end
  rescue => e
    puts "head: #{path}: #{e.message}"
    had_error = true
  end
end

exit 1 if had_error
