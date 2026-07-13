# johakyu: live coding UI for sound and light (research 06, M9).
#
# Usage from IRB:
#   johakyu               (edits /live.rb)
#   johakyu /my/show.rb
#
# Split screen: the top shows the clock, fixtures, and the raw DMX
# universe (changed channels flash inverted); the bottom is a Ruby
# editor reusing the edit.rb behavior (syntax highlight, auto indent,
# undo, IME). The show keeps running while editing: the main loop
# pumps the scheduler and the DMX keepalive on every iteration.
#
# Keybindings:
#   F5:      Evaluate the buffer (applies at the next cycle boundary)
#   Ctrl-S:  Save, then evaluate
#   Ctrl-Q:  Quit (blackout)
#   Ctrl-Z / Ctrl-Y: Undo / Redo
#
# The buffer is evaluated in a resident Sandbox task. The script only
# records intents through Johakyu::Live; the app task applies them to
# the running session afterwards, so a script error or endless loop
# never breaks the show (see rootfs/lib/johakyu/live.rb).

require "board/pwm_audio"
require "johakyu/live"
require "johakyu/universe_view"

class JohakyuApp
  VIEW_TOP    = 0
  STATUS_ROW  = Johakyu::UniverseView::ROWS       # row 6
  EDIT_TOP    = STATUS_ROW + 1
  EDIT_BOTTOM = Console.rows - 2
  EDIT_ROWS   = EDIT_BOTTOM - EDIT_TOP + 1
  COMMAND_ROW = Console.rows - 1

  STATUS_ATTR  = 0x0F
  COMMAND_ATTR = 0x0F
  EDIT_ATTR    = 0xF0

  UNDO_MAX = 200
  EVAL_TIMEOUT_MS = 2000

  # Windowed syntax analysis (same design as edit.rb): only a window
  # of lines around the viewport is parsed, rebuilt on edits or when
  # the viewport leaves the window. Scrolling alone reuses the cached
  # map, so it neither reparses nor reallocates the joined source.
  SYNTAX_MARGIN      = 40
  SYNTAX_ANCHOR_SCAN = 60
  SYNTAX_MAX_BYTES   = 8100

  STARTER = [
    "tempo 120",
    "",
    "track(:drums) { sound(\"bd ~ [sd sd] ~, hh*8\").color(\"<red blue>\").on(:s1) }",
    "",
    "track(:wash) { dmx(:s2).dimmer(sine.slow(2)).pan(sine.range(0.3, 0.7).slow(8)) }",
    "",
    "# F1/F2/F3 load the jo/ha/kyu scenes; F5 applies the buffer.",
  ]

  SCENES = {
    1 => ["/data/johakyu/jo.rb", "jo"],
    2 => ["/data/johakyu/ha.rb", "ha"],
    3 => ["/data/johakyu/kyu.rb", "kyu"],
  }
  CATALOG_PATH = "/data/johakyu/catalog.rb"

  def initialize(filepath)
    @console = $console
    @keyboard = $keyboard
    @filepath = filepath || "/live.rb"

    @buffer = Editor::Buffer.new
    @scroll_top = 0
    @scroll_left = 0
    @running = true
    @message = nil
    @undo_stack = []
    @redo_stack = []
    @syntax = nil     # [highlight_map, window_offsets, win_start] or nil
    @win_start = 0
    @win_end = 0
    @command_bar_text = nil
    @command_bar_mode = false

    @evaling = false
    @eval_started_ms = 0
    @preedit_width = 0
  end

  def run
    setup_engine
    load_buffer
    analyze_viewport

    @view = Johakyu::UniverseView.new(@session, top: VIEW_TOP)
    @sandbox = new_eval_sandbox
    load_catalog

    @console.clear
    @view.reset
    draw_command_bar
    draw_all_lines
    draw_status
    place_cursor
    @console.commit

    main_loop
  ensure
    shutdown
  end

  private

  def setup_engine
    DMX.init
    DMX.start
    DMX.deadman_ms = 500
    DMX.active_slots = Johakyu.patch.max_channel
    @audio = Board::PWMAudio.new
    @session = Johakyu::Session.new(audio: @audio, bpm: 120)
    # Attach the drum samples; without this the sound reservations
    # land on sourceless channels and play silence.
    @session.load_kit
    @live = Johakyu::Live.new(@session)
    $johakyu_live = @live
  end

  def shutdown
    @sandbox.terminate if @sandbox
    @session.stop_sounds if @session
    @audio.deinit if @audio
    DMX.blackout
    8.times do
      DMX.keepalive
      sleep_ms 25
    end
    DMX.stop
    @console.hide_cursor
    @console.clear
    @console.commit
  end

  # -- Main loop: the show never waits for a key. --

  def main_loop
    while @running
      @session.update
      DMX.keepalive
      poll_eval

      c = @keyboard.read_char
      if c
        handle_key(c)
      end

      @view.draw
      @console.commit
      sleep_ms 5
    end
  end

  # -- Live eval --

  # Resident sandbox, primed once so later compiles reuse the task
  # (the irb compile/execute/suspend pattern).
  def new_eval_sandbox
    sandbox = Sandbox.new("johakyu-live")
    sandbox.compile("_ = nil")
    sandbox.execute
    sandbox.wait(timeout: nil)
    sandbox.suspend
    sandbox
  end

  # Evaluate the jo/ha/kyu catalog once at startup. Its top-level
  # definitions are global, so every later buffer eval sees them; the
  # resident sandbox does not need a reload.
  def load_catalog
    source = nil
    begin
      source = File.open(CATALOG_PATH, "r") { |f| f.read }
    rescue
      source = nil
    end
    if source.nil? || source.bytesize == 0
      @message = "catalog missing: #{CATALOG_PATH}"
      return
    end
    if @sandbox.compile(source)
      @sandbox.execute
      @sandbox.wait(timeout: 3000)
      @sandbox.suspend
      error = @sandbox.result
      if error.is_a?(Exception)
        @message = "catalog: #{error.message}"
      end
    else
      @message = "catalog failed to compile"
    end
  end

  # Load a jo/ha/kyu scene file into the buffer (F1-F3). Nothing is
  # applied until F5, like any other edit.
  def load_scene(number)
    entry = SCENES[number]
    return unless entry
    source = nil
    begin
      source = File.open(entry[0], "r") { |f| f.read }
    rescue
      source = nil
    end
    if source.nil? || source.bytesize == 0
      @message = "scene missing: #{entry[0]}"
      return
    end
    @buffer.lines.clear
    source.split("\n").each { |l| @buffer.lines.push(l) }
    @buffer.lines.push("") if @buffer.lines.empty?
    @buffer.move_to(0, 0)
    @scroll_top = 0
    @scroll_left = 0
    @undo_stack.clear
    @redo_stack.clear
    @buffer.mark_dirty(:structure)
    @message = "Scene #{entry[1]} loaded - F5 to apply"
  end

  def start_eval
    return if @evaling
    source = @buffer.lines.join("\n")
    @live.begin_recording
    if @sandbox.compile(source)
      @sandbox.execute
      @evaling = true
      @eval_started_ms = Machine.board_millis
      @message = "Evaluating..."
    else
      @live.discard
      @message = "Syntax error (buffer not applied)"
    end
    draw_status
  end

  def poll_eval
    return unless @evaling
    state = @sandbox.state
    if state == :DORMANT || state == :SUSPENDED
      @evaling = false
      error = @sandbox.error
      if error && !error.is_a?(SystemExit)
        @live.discard
        location = nil
        if error.respond_to?(:backtrace)
          backtrace = error.backtrace
          location = backtrace[0] if backtrace && backtrace.length > 0
        end
        if location
          @message = "#{location}: #{error.message} (#{error.class})"
        else
          @message = "#{error.message} (#{error.class})"
        end
      else
        @live.apply
        @message = "Applied (next cycle)"
      end
      @sandbox.suspend
      draw_status
    elsif Machine.board_millis - @eval_started_ms > EVAL_TIMEOUT_MS
      # Do not stop a running task: the stop flag forces a return out
      # of a possibly nested mrb_vm_exec and hardfaults (the known
      # mruby-task nested-exec family). Suspending only parks the task
      # at its next safe point, so the runaway script is abandoned and
      # a fresh sandbox takes over.
      @sandbox.suspend
      @sandbox = new_eval_sandbox
      @live.discard
      @evaling = false
      @message = "Eval timeout: scripts must not loop (bindings keep running)"
      draw_status
    end
  end

  # -- File I/O --

  def load_buffer
    @buffer.lines.clear
    if File.exist?(@filepath)
      content = File.open(@filepath, "r") { |f| f.read }
      if content
        content.split("\n").each { |l| @buffer.lines.push(l) }
      end
    else
      STARTER.each { |l| @buffer.lines.push(l) }
    end
    @buffer.lines.push("") if @buffer.lines.empty?
    @buffer.changed = false
  end

  def save_buffer
    File.open(@filepath, "w") do |f|
      f.write(@buffer.lines.join("\n") + "\n")
    end
    @buffer.changed = false
    @message = "Saved #{@filepath}"
  rescue => e
    @message = "Save failed: #{e.message}"
  end

  # -- Undo plumbing (same behavior as edit.rb) --

  def undo_record(entry)
    last = @undo_stack[-1]
    if last && entry[0] == :insert && last[0] == :insert &&
       entry[1] == last[1] && entry[2] == last[2] + last[3].bytesize
      last[3] += entry[3]
      return
    end
    if last && entry[0] == :delete && last[0] == :delete &&
       entry[1] == last[1] && entry[2] == last[2]
      last[3] += entry[3]
      return
    end
    if last && entry[0] == :delete && last[0] == :delete &&
       entry[1] == last[1] && entry[2] + entry[3].bytesize == last[2]
      last[2] = entry[2]
      last[3] = entry[3] + last[3]
      return
    end
    @undo_stack.push(entry)
    @undo_stack.shift if @undo_stack.length > UNDO_MAX
  end

  def undo_record_break
    @undo_stack.push(nil) if @undo_stack[-1] != nil && @undo_stack.length > 0
  end

  def apply_entry(entry)
    type, y, x, text = entry
    case type
    when :insert
      @buffer.move_to(x, y)
      line = @buffer.lines[y]
      @buffer.lines[y] = line.byteslice(0, x).to_s + text + line.byteslice(x, 65535).to_s
      @buffer.move_to(x + text.bytesize, y)
    when :delete
      @buffer.move_to(x, y)
      line = @buffer.lines[y]
      @buffer.lines[y] = line.byteslice(0, x).to_s + line.byteslice(x + text.bytesize, 65535).to_s
    when :split
      line = @buffer.lines[y]
      @buffer.lines[y] = line.byteslice(0, x).to_s
      @buffer.lines.insert(y + 1, line.byteslice(x, 65535).to_s)
      @buffer.move_to(0, y + 1)
    when :join
      @buffer.lines[y] = @buffer.lines[y] + @buffer.lines[y + 1]
      @buffer.lines.delete_at(y + 1)
      @buffer.move_to(x, y)
    end
    @buffer.mark_dirty(:structure)
    @buffer.changed = true
  end

  def reverse_type(type)
    case type
    when :insert then :delete
    when :delete then :insert
    when :split then :join
    when :join then :split
    end
  end

  def perform_undo
    @undo_stack.pop while @undo_stack[-1] == nil && @undo_stack.length > 0
    entry = @undo_stack.pop
    return false unless entry
    apply_entry([reverse_type(entry[0]), entry[1], entry[2], entry[3]])
    @redo_stack.push(entry)
    true
  end

  def perform_redo
    entry = @redo_stack.pop
    return false unless entry
    apply_entry(entry)
    @undo_stack.push(entry)
    true
  end

  # -- Syntax (windowed, same design as edit.rb) --

  # A line starting at column 0 with a top-level construct boundary is
  # a safe place to start parsing.
  def syntax_anchor?(line)
    return false if line.bytesize == 0
    b0 = line.getbyte(0)
    return false if b0 == 0x20 || b0 == 0x09
    return true if line == "end"
    line.start_with?("class ", "class\t", "module ", "module\t", "def ", "def\t")
  end

  def syntax_anchor_line(from_line)
    from_line = 0 if from_line < 0
    limit = from_line - SYNTAX_ANCHOR_SCAN
    limit = 0 if limit < 0
    i = from_line
    while i > limit
      line = @buffer.lines[i]
      return i if line && syntax_anchor?(line)
      i -= 1
    end
    limit
  end

  # Parse a window covering [top, bottom] plus margins, capped to the
  # analyzer byte budget. Returns the raw result and updates the
  # cached bundle (@syntax = [highlight_map, offsets, win_start]).
  def analyze_window(top, bottom)
    lines = @buffer.lines
    n = lines.length
    if n == 0
      @syntax = nil
      @win_start = 0
      @win_end = 0
      return nil
    end
    top = 0 if top < 0
    bottom = n - 1 if bottom > n - 1
    bottom = top if bottom < top

    ws = syntax_anchor_line(top - SYNTAX_MARGIN)
    we = bottom + SYNTAX_MARGIN + 1
    we = n if we > n

    total = 0
    i = ws
    while i < we
      total += lines[i].bytesize + 1
      i += 1
    end
    while total > SYNTAX_MAX_BYTES && we > bottom + 1
      we -= 1
      total -= lines[we].bytesize + 1
    end
    while total > SYNTAX_MAX_BYTES && ws < top
      total -= lines[ws].bytesize + 1
      ws += 1
    end

    @win_start = ws
    @win_end = we
    source = lines[ws...we].join("\n")
    result = RubySyntax.analyze(source)
    unless result
      @syntax = nil
      return nil
    end
    offsets = []
    off = 0
    i = ws
    while i < we
      offsets.push(off)
      off += lines[i].bytesize + 1
      i += 1
    end
    @syntax = [result.highlight_map, offsets, ws]
    result
  end

  def analyze_viewport
    analyze_window(@scroll_top, @scroll_top + EDIT_ROWS - 1)
  end

  # -- Drawing --

  # Cursor movement redraws this row on every key (repeat runs at
  # 20 Hz), so it must stay allocation-light next to the audio fill:
  # no display_slice (it allocates one String per character).
  def draw_status
    line_num = @buffer.cursor_y + 1
    col_num = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x) + 1
    modified = @buffer.changed ? " [+]" : ""
    status = " #{@filepath}#{modified}  #{line_num}:#{col_num}"
    status = " #{@message}" if @message
    width = Editor.display_width(status)
    if width < Console.cols
      status += " " * (Console.cols - width)
    elsif width > Console.cols
      status = Editor.display_slice(status, 0, Console.cols)
    end
    @console.put_string_at(0, STATUS_ROW, status, STATUS_ATTR)
  end

  # The bar text only changes with the IME mode label; cache the
  # padded string so per-key redraw is one put_string, no allocation.
  def draw_command_bar
    mode = $ime ? $ime.mode_label : nil
    if @command_bar_text.nil? || mode != @command_bar_mode
      @command_bar_mode = mode
      bar = " F1-F3:Scene  F5:Eval  Ctrl-S:Save+Eval  Ctrl-Q:Quit  Ctrl-Z:Undo"
      if mode
        padding = Console.cols - Editor.display_width(bar) - Editor.display_width(mode)
        bar += " " * padding if padding > 0
        bar += mode
      else
        padding = Console.cols - Editor.display_width(bar)
        bar += " " * padding if padding > 0
      end
      @command_bar_text = bar
    end
    @console.put_string_at(0, COMMAND_ROW, @command_bar_text, COMMAND_ATTR)
  end

  # Prompt on the command bar. Keeps the show alive while waiting.
  def prompt_input(label, y_or_n: false)
    input = ""
    loop do
      display = " #{label}#{input}"
      padding = Console.cols - Editor.display_width(display)
      display += " " * padding if padding > 0
      @console.put_string_at(0, COMMAND_ROW, Editor.display_slice(display, 0, Console.cols), COMMAND_ATTR)
      @console.commit

      c = @keyboard.read_char
      unless c
        @session.update
        DMX.keepalive
        poll_eval
        @view.draw
        sleep_ms 5
        next
      end

      case c
      when Keyboard::ENTER
        return input
      when Keyboard::ESCAPE
        return nil
      when Keyboard::BSPACE
        if input.bytesize > 0
          input = input.byteslice(0, Editor.prev_char_byte_pos(input, input.bytesize))
        end
      else
        if c.printable?
          ch = c.to_s
          if y_or_n
            return ch if ch == "y" || ch == "Y" || ch == "n" || ch == "N"
          else
            input += ch
          end
        end
      end
    end
  end

  def draw_line(screen_row)
    row = EDIT_TOP + screen_row
    line_index = @scroll_top + screen_row
    @console.clear_line(row)
    return if line_index >= @buffer.lines.length

    line = @buffer.lines[line_index]
    line_offset = nil
    if @syntax
      rel = line_index - @syntax[2]
      line_offset = @syntax[1][rel] if rel >= 0 && rel < @syntax[1].length
    end
    if line_offset
      RubySyntax.draw_line(0, row, line, @syntax[0], line_offset, @scroll_left, Console.cols, EDIT_ATTR)
    else
      text = Editor.display_slice(line, @scroll_left, Console.cols)
      @console.put_string_at(0, row, text, EDIT_ATTR) if text && text.bytesize > 0
    end
  end

  def draw_all_lines
    i = 0
    while i < EDIT_ROWS
      draw_line(i)
      i += 1
    end
  end

  # Differential vertical scroll: shift with the DVI ring-buffer
  # scroll (O(1)) and draw only the newly exposed lines. The ring
  # scroll moves the whole screen, so the universe view, status row,
  # and command bar are repainted in the same frame.
  def scroll_view(vdelta)
    if vdelta > 0
      DVI::Text.scroll_up(vdelta, EDIT_ATTR)
      row = EDIT_ROWS - vdelta
      while row < EDIT_ROWS
        draw_line(row)
        row += 1
      end
    else
      n = -vdelta
      DVI::Text.scroll_down(n, EDIT_ATTR)
      row = 0
      while row < n
        draw_line(row)
        row += 1
      end
    end
    @view.reset
    draw_command_bar
  end

  # Horizontal scroll has no ring-buffer shortcut; redraw the visible
  # lines whose content moved, skipping lines blank in both viewports.
  def draw_hscroll(old_scroll_left)
    threshold = old_scroll_left < @scroll_left ? old_scroll_left : @scroll_left
    i = 0
    while i < EDIT_ROWS
      line = @buffer.lines[@scroll_top + i]
      if line.nil? || Editor.display_width(line) <= threshold
        i += 1
        next
      end
      draw_line(i)
      i += 1
    end
  end

  def place_cursor
    screen_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x) - @scroll_left + @preedit_width
    screen_row = EDIT_TOP + @buffer.cursor_y - @scroll_top
    @console.move_to(screen_col, screen_row)
    @console.show_cursor
  end

  # -- Scrolling --

  def adjust_vertical_scroll
    if @buffer.cursor_y < @scroll_top
      return @buffer.cursor_y
    end
    if @buffer.cursor_y >= @scroll_top + EDIT_ROWS
      return @buffer.cursor_y - EDIT_ROWS + 1
    end
    @scroll_top
  end

  # Jump-scroll horizontally (re-center) when the cursor leaves the
  # window, so per-column movement does not force full-width redraws.
  def adjust_horizontal_scroll
    line_width = Editor.display_width(@buffer.current_line)
    return 0 if line_width <= Console.cols
    cursor_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x)
    if cursor_col >= @scroll_left && cursor_col < @scroll_left + Console.cols
      return @scroll_left
    end
    new_scroll = cursor_col - Console.cols / 2
    max_scroll = line_width - Console.cols + 1
    new_scroll = max_scroll if new_scroll > max_scroll
    new_scroll = 0 if new_scroll < 0
    new_scroll
  end

  # -- Key handling (edit.rb behavior + F5/Ctrl-S eval) --

  def handle_key(c)
    @console.hide_cursor
    @message = nil
    @preedit_width = 0
    old_dirty = @buffer.dirty
    @old_scroll_top = @scroll_top
    @old_scroll_left = @scroll_left
    @buffer.clear_dirty

    ime_handled = false
    if $ime
      ime_result = $ime.process(c)
      case ime_result
      when :commit
        text = $ime.take_committed
        @redo_stack.clear
        undo_record([:insert, @buffer.cursor_y, @buffer.cursor_x, text])
        @buffer.put(text)
        ime_handled = true
      when :consumed
        @buffer.mark_dirty(:content)
        ime_handled = true
      end
    end

    unless ime_handled
      case c
      when Keyboard::CTRL_Q, Keyboard::CTRL_C
        answer = prompt_input("Quit and blackout? (y/n): ", y_or_n: true)
        draw_command_bar
        @buffer.mark_dirty(:structure)
        if answer && (answer == "y" || answer == "Y")
          @running = false
          return
        end
        @message = "Quit cancelled"
      when Keyboard::CTRL_S
        save_buffer
        start_eval
      when Keyboard::F5
        start_eval
      when Keyboard::F1
        load_scene(1)
      when Keyboard::F2
        load_scene(2)
      when Keyboard::F3
        load_scene(3)
      when Keyboard::CTRL_Z
        @message = "Undo" if perform_undo
      when Keyboard::CTRL_Y
        @message = "Redo" if perform_redo
      when Keyboard::PAGEUP
        @scroll_top -= EDIT_ROWS
        @scroll_top = 0 if @scroll_top < 0
        @buffer.move_to(@buffer.cursor_x, @scroll_top)
      when Keyboard::PAGEDOWN
        max_scroll = @buffer.lines.length - EDIT_ROWS
        max_scroll = 0 if max_scroll < 0
        @scroll_top += EDIT_ROWS
        @scroll_top = max_scroll if @scroll_top > max_scroll
        new_y = @scroll_top + EDIT_ROWS - 1
        new_y = @buffer.lines.length - 1 if new_y >= @buffer.lines.length
        @buffer.move_to(@buffer.cursor_x, new_y)
      when Keyboard::HOME
        undo_record_break
        @buffer.head
      when Keyboard::END_KEY
        undo_record_break
        @buffer.tail
      when Keyboard::DELETE
        @redo_stack.clear
        undo_record_break
        if @buffer.cursor_x >= @buffer.current_line.bytesize && @buffer.cursor_y + 1 < @buffer.lines.length
          undo_record([:join, @buffer.cursor_y, @buffer.cursor_x])
          @buffer.lines[@buffer.cursor_y] = @buffer.current_line + @buffer.lines[@buffer.cursor_y + 1]
          @buffer.lines.delete_at(@buffer.cursor_y + 1)
          @buffer.changed = true
          @buffer.mark_dirty(:structure)
        else
          if @buffer.cursor_x < @buffer.current_line.bytesize
            deleted = Editor.char_at_bytepos(@buffer.current_line, @buffer.cursor_x)
            undo_record([:delete, @buffer.cursor_y, @buffer.cursor_x, deleted])
          end
          @buffer.delete
          @buffer.mark_dirty(:content)
        end
      when Keyboard::ENTER
        @redo_stack.clear
        undo_record([:split, @buffer.cursor_y, @buffer.cursor_x])
        undo_record_break
        @buffer.put(c.to_buffer_input)
        auto_indent
      when Keyboard::BSPACE
        @redo_stack.clear
        if @buffer.cursor_x > 0
          prev_pos = Editor.prev_char_byte_pos(@buffer.current_line, @buffer.cursor_x)
          deleted = @buffer.current_line.byteslice(prev_pos, @buffer.cursor_x - prev_pos)
          undo_record([:delete, @buffer.cursor_y, prev_pos, deleted])
        elsif @buffer.cursor_y > 0
          undo_record_break
          undo_record([:join, @buffer.cursor_y - 1, @buffer.lines[@buffer.cursor_y - 1].bytesize])
        end
        @buffer.put(c.to_buffer_input)
      when Keyboard::UP, Keyboard::DOWN, Keyboard::LEFT, Keyboard::RIGHT
        undo_record_break
        @buffer.put(c.to_buffer_input)
      when Keyboard::ESCAPE
        # Ignore
      else
        if c.printable?
          @redo_stack.clear
          undo_record([:insert, @buffer.cursor_y, @buffer.cursor_x, c.to_s])
          @buffer.put(c.to_s)
          if c.to_s == " " && RubySyntax.should_dedent_on_space?(@buffer.current_line)
            result = analyze_window(@buffer.cursor_y, @buffer.cursor_y)
            if result
              old_line = @buffer.current_line
              if RubySyntax.reindent_line(@buffer, @buffer.cursor_y, result.indent_level(@buffer.cursor_y - @win_start))
                undo_record([:replace_line, @buffer.cursor_y, old_line])
                @buffer.mark_dirty(:content)
              end
            end
          end
        else
          input = c.to_buffer_input
          @buffer.put(input) if input
        end
      end
    end

    redraw_after_key(old_dirty)
  end

  def auto_indent
    result = analyze_window(@buffer.cursor_y - 1, @buffer.cursor_y)
    return unless result
    prev_y = @buffer.cursor_y - 1
    if prev_y >= 0
      old_line = @buffer.lines[prev_y]
      if RubySyntax.reindent_line(@buffer, prev_y, result.indent_level(prev_y - @win_start))
        undo_record([:replace_line, prev_y, old_line])
      end
    end
    level = result.indent_level(@buffer.cursor_y - @win_start)
    if level > 0
      spaces = "  " * level
      undo_record([:insert, @buffer.cursor_y, 0, spaces])
      @buffer.put(spaces)
    end
  end

  def redraw_after_key(old_dirty)
    # Scrolling is a viewport change, not a buffer change: it does not
    # mark the buffer dirty and does not reparse. The differential
    # paths below redraw only what moved.
    @scroll_top = adjust_vertical_scroll
    @scroll_left = adjust_horizontal_scroll

    dirty = @buffer.dirty
    dirty = old_dirty if dirty == :none && old_dirty != :none
    vdelta = @scroll_top - @old_scroll_top
    hscrolled = @scroll_left != @old_scroll_left

    content_changed = dirty == :content || dirty == :structure
    window_rebuilt = false
    vis_bottom = @scroll_top + EDIT_ROWS
    vis_bottom = @buffer.lines.length if vis_bottom > @buffer.lines.length
    if content_changed || @scroll_top < @win_start || vis_bottom > @win_end
      analyze_viewport
      window_rebuilt = true
    end

    if dirty == :structure || vdelta.abs >= EDIT_ROWS ||
       (hscrolled && vdelta != 0) || (window_rebuilt && !content_changed)
      draw_all_lines
    elsif hscrolled
      draw_hscroll(@old_scroll_left)
    elsif vdelta != 0
      scroll_view(vdelta)
      if dirty == :content
        draw_line(@buffer.cursor_y - @scroll_top)
      end
    elsif dirty == :content
      draw_line(@buffer.cursor_y - @scroll_top)
    end

    draw_status

    @preedit_width = 0
    if $ime && $ime.preedit.bytesize > 0
      cursor_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x) - @scroll_left
      preedit_row = EDIT_TOP + @buffer.cursor_y - @scroll_top
      if preedit_row >= EDIT_TOP && preedit_row <= EDIT_BOTTOM
        max_preedit = Console.cols - cursor_col
        if max_preedit > 0
          visible = Editor.display_slice($ime.preedit, 0, max_preedit)
          if visible && visible.bytesize > 0
            DVI::Text.put_string(cursor_col, preedit_row, visible, InputMethod::PREEDIT_ATTR)
            @preedit_width = Editor.display_width(visible)
          end
        end
      end
    end

    if $ime && $ime.candidates
      cand_text = ""
      ci = 0
      $ime.candidates.each do |cand|
        break if ci >= 7
        cand_text += " " if ci > 0
        cand_text += "#{ci + 1}:#{cand}"
        ci += 1
      end
      mode = $ime.mode_label
      if mode
        padding = Console.cols - Editor.display_width(cand_text) - Editor.display_width(mode)
        cand_text += " " * padding if padding > 0
        cand_text += mode
      else
        padding = Console.cols - Editor.display_width(cand_text)
        cand_text += " " * padding if padding > 0
      end
      @console.put_string_at(0, COMMAND_ROW, Editor.display_slice(cand_text, 0, Console.cols), COMMAND_ATTR)
    else
      draw_command_bar
    end

    place_cursor
  end
end

JohakyuApp.new(ARGV[0]).run
