# rm: Remove files
#
# Usage from IRB:
#   rm file.txt
#   rm file1.txt file2.txt

require "option_parser"

opts = OptionParser.new
opts.banner = "Usage: rm <file> [file ...]"
opts.parse!(ARGV)

if ARGV.empty?
  puts "rm: missing operand"
  exit 1
end

ARGV.each do |path|
  unless File.exist?(path)
    puts "rm: #{path}: No such file or directory"
    next
  end
  if File.directory?(path)
    puts "rm: #{path}: Is a directory (use rmdir)"
    next
  end
  begin
    File.unlink(path)
  rescue => e
    puts "rm: #{path}: #{e.message}"
  end
end
