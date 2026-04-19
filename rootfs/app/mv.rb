# mv: Move or rename a file
#
# Usage from IRB:
#   mv old_name.txt new_name.txt
#   mv file.txt /path/to/dir/
#   mv -f file.txt existing.txt   (force overwrite)

require "option_parser"

force = false
opts = OptionParser.new
opts.banner = "Usage: mv [-f] <source> <target>"
opts.on("-f", "Force overwrite if target exists") { force = true }
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

# If target is a directory, append source filename. Strip any trailing
# slash first so "dir/" and "dir" both produce "dir/name" rather than
# "dir//name".
target = target.chomp("/") if target.length > 1 && target.end_with?("/")
if File.directory?(target)
  name = source.split("/")[-1]
  target = "#{target}/#{name}"
end

if File.exist?(target)
  if force
    # VFS.rename refuses to overwrite, so remove the target first.
    File.unlink(target)
  else
    puts "mv: #{target}: already exists (use -f to overwrite)"
    exit 1
  end
end

begin
  File.rename(source, target)
rescue => e
  puts "mv: #{e.message}"
end
