# rmdir: Remove an empty directory
#
# Usage from IRB:
#   rmdir dirname
#   rmdir -f /lib     (force; bypasses system-path protection)

require "option_parser"

# Paths the OS needs to boot. Removing these directories (after emptying
# them) bricks the board until a BOOTSEL reflash. -f overrides.
PROTECTED = ["/lib", "/app", "/etc"]

def protected?(resolved)
  PROTECTED.any? { |p| resolved == p || resolved.start_with?("#{p}/") }
end

force = false
opts = OptionParser.new
opts.banner = "Usage: rmdir [-f] <directory>"
opts.on("-f", "Force; bypass system-path protection") { force = true }
opts.parse!(ARGV)

unless ARGV[0]
  puts "rmdir: missing operand"
  exit 1
end

path = ARGV[0]
resolved = File.expand_path(path)

if !force && protected?(resolved)
  puts "rmdir: #{path}: protected system path (use -f to override)"
  exit 1
end

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
