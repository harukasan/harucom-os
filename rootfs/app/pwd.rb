# pwd: Print working directory
#
# Usage from IRB:
#   pwd

require "option_parser"

opts = OptionParser.new
opts.banner = "Usage: pwd"
opts.parse!(ARGV)

puts Dir.pwd
