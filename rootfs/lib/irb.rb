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
    @stopped = nil # Single job-control slot for a suspended app

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
          @sandbox.compile("begin; _ = (#{input}\n); rescue Exception => _; end; _")
        end
      end

      break unless script # Ctrl-D

      script = script.chomp
      next if script.empty?
      break if script == "exit" || script == "quit"

      # Job control: resume or list a suspended app
      if script == "fg"
        resume_job
        @console.commit
        next
      end
      if script == "jobs"
        puts @stopped ? "[stopped] #{@stopped[:name]}" : "no stopped jobs"
        @console.commit
        next
      end

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
    @stopped[:sandbox].terminate if @stopped
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
    supervise(sandbox, name, path)
  end

  # Resume the stopped app (the `fg` command).
  def resume_job
    unless @stopped
      puts "fg: no stopped job"
      return
    end
    job = @stopped
    job[:sandbox].resume
    supervise(job[:sandbox], job[:name], job[:path])
  end

  # Wait for an app to finish or suspend, then dispose of it.
  # On Ctrl-Z the app suspends itself (state :SUSPENDED): keep its VM alive
  # as a stopped job and hand control back to the shell in text mode.
  # Otherwise the app finished or was interrupted: report any error and
  # terminate it.
  def supervise(sandbox, name, path)
    if wait_app(sandbox) == :suspended
      if @stopped && @stopped[:sandbox] != sandbox
        @stopped[:sandbox].terminate # Only one stopped job is tracked
      end
      @stopped = { sandbox: sandbox, name: name, path: path }
      DVI.set_mode(DVI::TEXT_MODE)
      puts "[stopped] #{name}"
      @console.commit
    else
      if (error = sandbox.error) && !error.is_a?(SystemExit)
        puts "#{path}: #{error.message} (#{error.class})"
        if error.respond_to?(:backtrace) && (bt = error.backtrace)
          bt.each { |line| puts "  #{line}" }
        end
      end
      DVI.set_mode(DVI::TEXT_MODE)
      sandbox.terminate
      @stopped = nil if @stopped && @stopped[:sandbox] == sandbox
    end
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

  # Wait for an app sandbox to finish or suspend.
  # Uses Keyboard#ctrl_c_pressed? flag instead of reading from the queue,
  # so the app can still receive all key events including Ctrl-C.
  # Returns :interrupted on Ctrl-C, :suspended when the app suspended
  # itself (Ctrl-Z), or :done when it ran to completion.
  def wait_app(sandbox)
    sleep_ms 5
    while sandbox.state != :DORMANT && sandbox.state != :SUSPENDED
      if @keyboard.ctrl_c_pressed?
        sandbox.stop
        puts "^C"
        @console.commit
        return :interrupted
      end
      sleep_ms 5
    end
    sandbox.state == :SUSPENDED ? :suspended : :done
  end
end
