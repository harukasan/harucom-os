# cat: Display file contents
#
# Usage from IRB:
#   cat file.rb
#   cat -n file.rb
#   cat file1.rb file2.rb

require "option_parser"

options = {}
opts = OptionParser.new
opts.banner = "Usage: cat [options] <file> [file ...]"
opts.on("-n", "Number output lines") { options[:n] = true }
opts.parse!(ARGV)

if ARGV.empty?
  puts "cat: missing file operand"
  exit 1
end

lineno = 0
had_error = false
ARGV.each do |path|
  unless File.exist?(path)
    puts "cat: #{path}: No such file or directory"
    had_error = true
    next
  end
  if File.directory?(path)
    puts "cat: #{path}: Is a directory"
    had_error = true
    next
  end
  begin
    File.open(path, "r") do |f|
      while line = f.gets
        lineno += 1
        if options[:n]
          print "#{lineno.to_s.rjust(6)} #{line}"
        else
          print line
        end
      end
    end
  rescue => e
    puts "cat: #{path}: #{e.message}"
    had_error = true
  end
end

exit 1 if had_error
