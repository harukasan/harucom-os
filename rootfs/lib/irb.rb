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

    # Highlight proc: returns app name byte length if line starts with an app name
    @editor.highlight_proc = ->(line) {
      word = line.split[0]
      if word && find_app(word)
        word.bytesize
      end
    }
  end

  def start
    @console.clear
    puts <<~PROMPT

      #{Console::BRIGHT_CYAN}#{Console::BOLD}Harucom#{Console::WHITE} OS#{Console::RESET} #{HARUCOM_VERSION} (#{HARUCOM_BUILD_DATE})
      (c) 2026 Shunsuke Michii

      Powered by PicoRuby #{PICORUBY_VERSION} on #{RUBY_PLATFORM}

      くわしい使い方は https://harucom.org/ をごらんください

    PROMPT
    @console.commit

    loop do
      script = @editor.readmultiline(PROMPT, PROMPT_CONT) do |input|
        if input.chomp.end_with?("\\")
          false
        elsif find_app(input.split[0])
          true
        else
          @sandbox.compile("begin; _ = (#{input}\n); rescue => _; end; _")
        end
      end

      break unless script # Ctrl-D

      script = script.chomp
      next if script.empty?
      break if script == "exit" || script == "quit"

      # Check for /app/ command before eval
      words = script.split
      if app_path = find_app(words[0])
        run_app(app_path, words[1..])
        @console.commit
        next
      end

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
    @sandbox.terminate if @sandbox
  end

  private

  def find_app(name)
    path = "/app/#{name}.rb"
    File.exist?(path) ? path : nil
  end

  def run_app(path, args)
    Object.const_set(:ARGV, []) unless Object.const_defined?(:ARGV)
    ARGV.clear
    args.each { |a| ARGV << a }
    name = path.split("/")[-1].sub(".rb", "")
    sandbox = Sandbox.new(name)
    sandbox.load_file(path, join: false)
    wait_app(sandbox)
    if error = sandbox.error
      return if error.is_a?(SystemExit)
      puts "#{path}: #{error.message} (#{error.class})"
      if error.respond_to?(:backtrace) && (bt = error.backtrace)
        bt.each { |line| puts "  #{line}" }
      end
    end
  ensure
    DVI.set_mode(DVI::TEXT_MODE)
    sandbox.terminate if sandbox
  end

  def wait_sandbox(sandbox = @sandbox)
    sleep_ms 5
    while sandbox.state != :DORMANT && sandbox.state != :SUSPENDED
      c = @keyboard.read_char
      if c == Keyboard::CTRL_C
        sandbox.stop
        puts "^C"
        @console.commit
        return
      end
      sleep_ms 5
    end
  end

  # Wait for an app sandbox to finish.
  # Uses Keyboard#ctrl_c_pressed? flag instead of reading from the queue,
  # so the app can still receive all key events including Ctrl-C.
  def wait_app(sandbox)
    sleep_ms 5
    while sandbox.state != :DORMANT && sandbox.state != :SUSPENDED
      if @keyboard.ctrl_c_pressed?
        sandbox.stop
        puts "^C"
        @console.commit
        return
      end
      sleep_ms 5
    end
  end
end
