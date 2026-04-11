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

require "console"
require "input_method"
require "input_method_skk"
require "input_method_tcode"
require "line_editor"
require "keyboard_input"
require "ruby_syntax"

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
