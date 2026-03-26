# run: Execute a Ruby script
#
# Usage from IRB:
#   run test.rb        (loads /test.rb)
#   run /app/test.rb   (absolute path)

path = ARGV[0]
unless path
  puts "Usage: run <file>"
  return
end

path = "/#{path}" unless path.start_with?("/")

unless File.exist?(path)
  puts "run: #{path}: file not found"
  return
end

load path
