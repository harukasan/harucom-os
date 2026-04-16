# cd: Change working directory
#
# Usage from IRB:
#   cd /app
#   cd ..
#   cd         (go to root)

require "option_parser"

opts = OptionParser.new
opts.banner = "Usage: cd [directory]"
opts.parse!(ARGV)

path = ARGV[0] || "/"

unless Dir.exist?(path)
  puts "cd: #{path}: No such directory"
  exit 1
end

Dir.chdir(path)
