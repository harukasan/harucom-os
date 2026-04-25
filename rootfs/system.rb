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

# Install keyboard layout selected via ENV["KEYBOARD_LAYOUT"]. Layouts are
# bundled in the picoruby-keyboard-input mrbgem as pre-compiled bytecode
# so boot does not pay for a literal-heavy runtime parse.
layout = ENV["KEYBOARD_LAYOUT"] || "us"
unless Keyboard.use_layout(layout)
  puts "unknown keyboard layout '#{layout}', falling back to us"
  Keyboard.use_layout("us")
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

# --- Autoexec ---
# Run /autoexec.rb at boot unless Ctrl-C is held during the grace window.
# Lets the board boot directly into an app (e.g. a game) while keeping
# Ctrl-C as the escape hatch back to IRB.
AUTOEXEC_PATH = "/autoexec.rb"
AUTOEXEC_DELAY_MS = 2000

if File.exist?(AUTOEXEC_PATH)
  puts
  puts "Auto-running #{AUTOEXEC_PATH} in #{AUTOEXEC_DELAY_MS / 1000}s (Ctrl-C to cancel)..."
  # Discard any Ctrl-C queued before the grace window opens.
  $keyboard.ctrl_c_pressed?
  cancelled = false
  deadline = Machine.board_millis + AUTOEXEC_DELAY_MS
  while Machine.board_millis < deadline
    if $keyboard.ctrl_c_pressed?
      cancelled = true
      break
    end
    sleep_ms 20
  end
  if cancelled
    puts "^C autoexec cancelled"
  else
    sandbox = Sandbox.new("autoexec")
    begin
      sandbox.load_file(AUTOEXEC_PATH, join: false)
      # Mirror IRB#wait_app: poll the keyboard flag so Ctrl-C from USB
      # stops autoexec. Machine.check_signal only sees UART/POSIX signals.
      while sandbox.state != :DORMANT && sandbox.state != :SUSPENDED
        if $keyboard.ctrl_c_pressed?
          sandbox.stop
          puts "^C"
          break
        end
        sleep_ms 5
      end
      if (err = sandbox.error) && !err.is_a?(SystemExit)
        puts "#{AUTOEXEC_PATH}: #{err.message} (#{err.class})"
      end
    ensure
      sandbox.terminate
      DVI.set_mode(DVI::TEXT_MODE) if defined?(DVI)
    end
  end
end

require "irb"
# IRB is the board's single long-running foreground session. Exit and any
# unhandled error should leave the user at a fresh prompt rather than a
# dead console, so restart IRB in a loop.
loop do
  begin
    IRB.new(console: $console, keyboard: $keyboard, line_editor: line_editor).start
  rescue Exception => e
    puts "IRB error: #{e.message} (#{e.class})"
    sleep_ms 1000
  end
end
