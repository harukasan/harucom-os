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
require "line_editor"
require "keyboard_input"

# Set up DVI as standard output (mirrored to UART internally)
console = Console.new
$stdout = console

# Set up USB keyboard as standard input
keyboard = Keyboard.new
line_editor = LineEditor.new(console: console, keyboard: keyboard)
$stdin = KeyboardInput.new(line_editor: line_editor)

require "irb"
IRB.new(console: console, keyboard: keyboard, line_editor: line_editor).start
