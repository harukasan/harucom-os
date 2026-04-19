# Harucom OS system entry point
#
# Starts background services, sets up I/O, and launches IRB.

# USB host background task
Task.new(name: "usb_host") do
  loop do
    USB::Host.task
    Task.pass
  end
end

# Load environment variables from /etc/env.yml into ENV. Missing or
# malformed file is non-fatal; ENV simply stays unpopulated.
require "env"
require "yaml"

# VFS.sanitize resolves relative paths against ENV["PWD"]. VFS.mount sets
# PWD only when it is already non-empty, so on fresh boot PWD is unset and
# Dir.pwd falls back to ENV_DEFAULT_HOME ("/home") which does not exist.
# Anchor PWD to root here so relative paths work from the first command.
ENV["PWD"] = "/"

begin
  env = YAML.load_file("/etc/env.yml")
  if env.is_a?(Hash)
    env.each do |key, value|
      ENV[key.to_s] = value.to_s
    end
  end
rescue => e
  puts "env.yml load failed: #{e.message}"
end

require "system_exit"
require "console"
require "input_method"
require "input_method_skk"
require "input_method_tcode"
require "line_editor"
require "keyboard_input"
require "ruby_syntax"

# Install keyboard layout selected via ENV["KEYBOARD_LAYOUT"]. Fall back to
# US on unknown/missing values so input still works.
layout = ENV["KEYBOARD_LAYOUT"] || "us"
begin
  require "keymap/#{layout}"
rescue LoadError
  puts "unknown keyboard layout '#{layout}', falling back to us"
  require "keymap/us"
end

# Set up DVI as standard output (mirrored to UART internally)
$console = Console.new
$stdout = $console

# Set up USB keyboard as standard input
$keyboard = Keyboard.new
$ime = InputMethod.new
line_editor = LineEditor.new(console: $console, keyboard: $keyboard, ime: $ime)
$stdin = KeyboardInput.new(line_editor: line_editor)

# Keyboard polling background task
Task.new(name: "keyboard") do
  begin
    loop do
      $keyboard.poll
      Task.pass
    end
  rescue Exception => e
    puts "keyboard task error: #{e.message} (#{e.class})"
  end
end

require "irb"
begin
  IRB.new(console: $console, keyboard: $keyboard, line_editor: line_editor).start
rescue Exception => e
  puts "IRB error: #{e.message} (#{e.class})"
end
