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
  EDIT_BOTTOM = Console::ROWS - 2
  EDIT_ROWS   = EDIT_BOTTOM - EDIT_TOP + 1
  COMMAND_ROW = Console::ROWS - 1

  STATUS_ATTR  = 0x0F
  COMMAND_ATTR = 0x0F
  EDIT_ATTR    = 0xF0

  UNDO_MAX = 200
  EVAL_TIMEOUT_MS = 2000

  STARTER = [
    "tempo 120",
    "",
    "sound(\"bd ~ [sn sn] ~, hh*8\")",
    "",
    "dmx(:s1).dimmer(\"1 0 0.5 0\").color(\"<red blue>\")",
    "dmx(:s2).dimmer(sine.slow(2)).pan(sine.range(0.3, 0.7).slow(8))",
  ]

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
    @syntax_result = nil
    @highlight_map = nil
    @line_offsets = nil

    @evaling = false
    @eval_started_ms = 0
    @preedit_width = 0
  end

  def run
    setup_engine
    load_buffer
    rebuild_syntax

    @view = Johakyu::UniverseView.new(@session, top: VIEW_TOP)
    @sandbox = Sandbox.new("johakyu-live")
    @sandbox.compile("_ = nil")
    @sandbox.execute
    @sandbox.wait(timeout: nil)
    @sandbox.suspend

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
        @message = "#{error.message} (#{error.class})"
      else
        @live.apply
        @message = "Applied (next cycle)"
      end
      @sandbox.suspend
      draw_status
    elsif Machine.board_millis - @eval_started_ms > EVAL_TIMEOUT_MS
      @sandbox.stop
      @live.discard
      @evaling = false
      @message = "Eval timeout (script must not loop)"
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

  # -- Syntax --

  def rebuild_syntax
    source = @buffer.lines.join("\n")
    result = RubySyntax.analyze(source)
    unless result
      @syntax_result = nil
      @highlight_map = nil
      @line_offsets = nil
      return
    end
    offsets = []
    offset = 0
    @buffer.lines.each { |l| offsets.push(offset); offset += l.bytesize + 1 }
    @syntax_result = result
    @highlight_map = result.highlight_map
    @line_offsets = offsets
  end

  # -- Drawing --

  def draw_status
    line_num = @buffer.cursor_y + 1
    col_num = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x) + 1
    modified = @buffer.changed ? " [+]" : ""
    status = " #{@filepath}#{modified}  #{line_num}:#{col_num}"
    status = " #{@message}" if @message
    padding = Console::COLS - Editor.display_width(status)
    status += " " * padding if padding > 0
    @console.put_string_at(0, STATUS_ROW, Editor.display_slice(status, 0, Console::COLS), STATUS_ATTR)
  end

  def draw_command_bar
    bar = " F5:Eval  Ctrl-S:Save+Eval  Ctrl-Q:Quit  Ctrl-Z:Undo  Ctrl-Y:Redo"
    mode = $ime ? $ime.mode_label : nil
    if mode
      padding = Console::COLS - Editor.display_width(bar) - Editor.display_width(mode)
      bar += " " * padding if padding > 0
      bar += mode
    else
      padding = Console::COLS - Editor.display_width(bar)
      bar += " " * padding if padding > 0
    end
    @console.put_string_at(0, COMMAND_ROW, Editor.display_slice(bar, 0, Console::COLS), COMMAND_ATTR)
  end

  # Prompt on the command bar. Keeps the show alive while waiting.
  def prompt_input(label, y_or_n: false)
    input = ""
    loop do
      display = " #{label}#{input}"
      padding = Console::COLS - Editor.display_width(display)
      display += " " * padding if padding > 0
      @console.put_string_at(0, COMMAND_ROW, Editor.display_slice(display, 0, Console::COLS), COMMAND_ATTR)
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
    if @highlight_map && @line_offsets
      RubySyntax.draw_line(0, row, line, @highlight_map, @line_offsets[line_index] || 0, @scroll_left, Console::COLS, EDIT_ATTR)
    else
      text = Editor.display_slice(line, @scroll_left, Console::COLS)
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

  def adjust_horizontal_scroll
    line_width = Editor.display_width(@buffer.current_line)
    return 0 if line_width <= Console::COLS
    cursor_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x)
    return cursor_col if cursor_col < @scroll_left
    if cursor_col >= @scroll_left + Console::COLS
      return cursor_col - Console::COLS + 1
    end
    @scroll_left
  end

  # -- Key handling (edit.rb behavior + F5/Ctrl-S eval) --

  def handle_key(c)
    @console.hide_cursor
    @message = nil
    @preedit_width = 0
    old_dirty = @buffer.dirty
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
      when Keyboard::CTRL_Z
        @message = "Undo" if perform_undo
      when Keyboard::CTRL_Y
        @message = "Redo" if perform_redo
      when Keyboard::PAGEUP
        @scroll_top -= EDIT_ROWS
        @scroll_top = 0 if @scroll_top < 0
        @buffer.move_to(@buffer.cursor_x, @scroll_top)
        @buffer.mark_dirty(:structure)
      when Keyboard::PAGEDOWN
        max_scroll = @buffer.lines.length - EDIT_ROWS
        max_scroll = 0 if max_scroll < 0
        @scroll_top += EDIT_ROWS
        @scroll_top = max_scroll if @scroll_top > max_scroll
        new_y = @scroll_top + EDIT_ROWS - 1
        new_y = @buffer.lines.length - 1 if new_y >= @buffer.lines.length
        @buffer.move_to(@buffer.cursor_x, new_y)
        @buffer.mark_dirty(:structure)
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
            source = @buffer.lines.join("\n")
            result = RubySyntax.analyze(source)
            if result
              old_line = @buffer.current_line
              if RubySyntax.reindent_line(@buffer, @buffer.cursor_y, result.indent_level(@buffer.cursor_y))
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
    source = @buffer.lines.join("\n")
    result = RubySyntax.analyze(source)
    return unless result
    prev_y = @buffer.cursor_y - 1
    if prev_y >= 0
      old_line = @buffer.lines[prev_y]
      if RubySyntax.reindent_line(@buffer, prev_y, result.indent_level(prev_y))
        undo_record([:replace_line, prev_y, old_line])
      end
    end
    level = result.indent_level(@buffer.cursor_y)
    if level > 0
      spaces = "  " * level
      undo_record([:insert, @buffer.cursor_y, 0, spaces])
      @buffer.put(spaces)
    end
  end

  def redraw_after_key(old_dirty)
    new_vscroll = adjust_vertical_scroll
    if new_vscroll != @scroll_top
      @scroll_top = new_vscroll
      @buffer.mark_dirty(:structure)
    end
    new_hscroll = adjust_horizontal_scroll
    if new_hscroll != @scroll_left
      @scroll_left = new_hscroll
      @buffer.mark_dirty(:structure)
    end

    dirty = @buffer.dirty
    dirty = old_dirty if dirty == :none && old_dirty != :none

    if dirty == :content || dirty == :structure
      rebuild_syntax
    end

    case dirty
    when :structure
      draw_all_lines
    when :content
      draw_line(@buffer.cursor_y - @scroll_top)
    end

    draw_status

    @preedit_width = 0
    if $ime && $ime.preedit.bytesize > 0
      cursor_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x) - @scroll_left
      preedit_row = EDIT_TOP + @buffer.cursor_y - @scroll_top
      if preedit_row >= EDIT_TOP && preedit_row <= EDIT_BOTTOM
        max_preedit = Console::COLS - cursor_col
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
        padding = Console::COLS - Editor.display_width(cand_text) - Editor.display_width(mode)
        cand_text += " " * padding if padding > 0
        cand_text += mode
      else
        padding = Console::COLS - Editor.display_width(cand_text)
        cand_text += " " * padding if padding > 0
      end
      @console.put_string_at(0, COMMAND_ROW, Editor.display_slice(cand_text, 0, Console::COLS), COMMAND_ATTR)
    else
      draw_command_bar
    end

    place_cursor
  end
end

JohakyuApp.new(ARGV[0]).run
