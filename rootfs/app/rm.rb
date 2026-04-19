# rm: Remove files
#
# Usage from IRB:
#   rm file.txt
#   rm file1.txt file2.txt
#   rm -f /lib/foo.rb   (force; bypasses system-path protection)

require "option_parser"

# Paths the OS needs to boot. Deleting these bricks the board until a
# BOOTSEL reflash, so block them by default. -f overrides the protection.
PROTECTED = ["/system.rb", "/lib", "/app", "/etc"]

def protected?(resolved)
  PROTECTED.any? { |p| resolved == p || resolved.start_with?("#{p}/") }
end

force = false
opts = OptionParser.new
opts.banner = "Usage: rm [-f] <file> [file ...]"
opts.on("-f", "Force; bypass system-path protection") { force = true }
opts.parse!(ARGV)

if ARGV.empty?
  puts "rm: missing operand"
  exit 1
end

ARGV.each do |path|
  resolved = File.expand_path(path)
  if !force && protected?(resolved)
    puts "rm: #{path}: protected system path (use -f to override)"
    next
  end
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
