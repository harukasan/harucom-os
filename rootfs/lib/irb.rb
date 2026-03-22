# IRB: Interactive Ruby on DVI text mode
#
# Uses LineEditor.readmultiline for input and Sandbox for execution.
# Supports multi-line input via try-compile, exit/quit commands,
# and the _ variable for the last result.

class IRB
  PROMPT      = "irb> "
  PROMPT_CONT = "..   "

  def initialize(console:, keyboard:, line_editor:)
    @console = console
    @keyboard = keyboard
    @editor = line_editor
    @sandbox = Sandbox.new("irb")
    @sandbox.compile("_ = nil")
    @sandbox.execute
    @sandbox.wait(timeout: nil)
    @sandbox.suspend
  end

  def start
    @console.clear
    puts "Harucom OS IRB"
    @console.commit

    loop do
      script = @editor.readmultiline(PROMPT, PROMPT_CONT) do |input|
        if input.chomp.end_with?("\\")
          false
        else
          @sandbox.compile("begin; _ = (#{input}); rescue => _; end; _")
        end
      end

      break unless script # Ctrl-D

      script = script.chomp
      next if script.empty?
      break if script == "exit" || script == "quit"

      @sandbox.execute
      wait_sandbox
      @sandbox.suspend

      if @sandbox.result.is_a?(Exception)
        puts "#{@sandbox.result.message} (#{@sandbox.result.class})"
      else
        puts "=> #{@sandbox.result.inspect}"
      end
      @console.commit
    end
  ensure
    @sandbox.terminate
  end

  private

  def wait_sandbox
    sleep_ms 5
    while @sandbox.state != :DORMANT && @sandbox.state != :SUSPENDED
      c = @keyboard.read_char
      if c == 3
        @sandbox.stop
        puts "^C"
        @console.commit
        return
      end
      sleep_ms 5
    end
  end
end
