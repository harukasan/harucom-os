# LineEditor: Reline-like line input on DVI text mode
#
# Provides readline and readmultiline methods using Console, Editor::Buffer,
# and Keyboard. Handles line editing, cursor rendering, and input area display.

class LineEditor
  attr_accessor :highlight_proc

  def initialize(console:, keyboard:, ime: nil)
    @console = console
    @keyboard = keyboard
    @ime = ime
    @buffer = Editor::Buffer.new
    @prompt = "> "
    @prompt_cont = "> "
    @prompt_width = 2
    @input_start_row = 0
    @highlight_proc = nil
  end

  # Single-line input
  # Returns the input string, or nil on Ctrl-D (EOF)
  def readline(prompt)
    readmultiline(prompt, nil) { true }
  end

  # Multi-line input
  # The block receives the current input and returns true if complete.
  # Returns the completed string, or nil on Ctrl-D (EOF)
  def readmultiline(prompt, prompt_cont, &check)
    @prompt = prompt
    @prompt_cont = prompt_cont || prompt
    @prompt_width = Editor.display_width(@prompt)
    @input_start_row = @console.row
    @buffer.clear
    @needs_refresh = true

    loop do
      if @needs_refresh
        refresh
        @console.commit
        @needs_refresh = false
      end

      c = @keyboard.read_char
      unless c
        DVI.wait_vsync
        next
      end
      @needs_refresh = true

      # Return to live view if scrolled back
      if @console.scroll_offset > 0
        case c
        when Keyboard::ENTER, Keyboard::BSPACE
          @console.scroll_forward(@console.scroll_offset)
        else
          @console.scroll_forward(@console.scroll_offset) if c.printable?
        end
      end

      # Process through input method if active
      if @ime
        ime_result = @ime.process(c)
        case ime_result
        when :commit
          @buffer.put(@ime.take_committed)
          next
        when :consumed
          next
        end
        # :passthrough falls through to normal handling
      end

      case c
      when Keyboard::CTRL_C
        feed
        @console.write("^C\n")
        @buffer.clear
        @input_start_row = @console.row
      when Keyboard::CTRL_D
        return nil if @buffer.empty?
      when Keyboard::CTRL_L
        @console.clear
        @input_start_row = 0
      when Keyboard::ENTER
        script = @buffer.dump.chomp
        if check.call(script)
          feed
          return script
        else
          @buffer.put(c.to_buffer_input)
        end
      when Keyboard::PAGEUP
        @console.scroll_back(Console::ROWS - 1)
      when Keyboard::PAGEDOWN
        @console.scroll_forward(Console::ROWS - 1)
      when Keyboard::UP
        @buffer.put(c.to_buffer_input) if @buffer.cursor_y > 0
      when Keyboard::DOWN
        @buffer.put(c.to_buffer_input) if @buffer.cursor_y < @buffer.lines.length - 1
      when Keyboard::DELETE
        @buffer.delete
      else
        if c.printable?
          @buffer.put(c.to_s)
        else
          input = c.to_buffer_input
          @buffer.put(input) if input
        end
      end
    end
  end

  private

  def refresh
    @console.hide_cursor

    lines = @buffer.lines
    line_count = lines.length

    # Reserve rows: input lines + candidate row (if active) + IME status row
    ime_active = @ime && @ime.mode_label
    reserved = line_count
    reserved += 1 if @ime && @ime.candidates  # candidate list row
    reserved += 1 if ime_active               # mode indicator row

    available_rows = Console::ROWS - @input_start_row
    if reserved > available_rows
      scroll_amount = reserved - available_rows
      @console.scroll_up(scroll_amount)
      @input_start_row -= scroll_amount
      @input_start_row = 0 if @input_start_row < 0
    end

    # Try custom highlight first, fall back to syntax highlighting
    custom = @highlight_proc && line_count == 1 && @highlight_proc.call(lines[0])

    unless custom
      source = lines.join("\n")
      highlight_map = SyntaxHighlight.tokenize(source)
      hl_offsets = nil
      if highlight_map
        hl_offsets = []
        offset = 0
        lines.each { |l| hl_offsets.push(offset); offset += l.bytesize + 1 }
      end
    end

    # Render each line
    max_line_width = Console::COLS - @prompt_width
    i = 0
    while i < line_count
      row = @input_start_row + i
      prompt = (i == 0) ? @prompt : @prompt_cont
      @console.clear_line(row)
      @console.put_string_at(0, row, prompt, @console.attr)
      if custom && i == 0
        draw_command_line(@prompt_width, row, lines[0], custom, max_line_width)
      elsif highlight_map && hl_offsets
        SyntaxHighlight.draw_line(@prompt_width, row, lines[i], highlight_map, hl_offsets[i] || 0, 0, max_line_width, @console.attr)
      else
        visible_text = Editor.display_slice(lines[i], 0, max_line_width)
        @console.put_string_at(@prompt_width, row, visible_text, @console.attr) if visible_text
      end
      i += 1
    end

    # Clear up to (but not including) IME status row
    clear_limit = ime_active ? Console::ROWS - 1 : Console::ROWS

    # Clear rows below input up to (but not including) IME status row
    clear_row = @input_start_row + line_count
    while clear_row < clear_limit
      @console.clear_line(clear_row)
      clear_row += 1
    end

    # Draw IME mode indicator on last row
    if ime_active
      label = @ime.mode_label
      ime_row = Console::ROWS - 1
      @console.clear_line(ime_row)
      label_col = Console::COLS - Editor.display_width(label)
      DVI::Text.put_string(label_col, ime_row, label, InputMethod::PREEDIT_ATTR)
    end

    # Draw preedit overlay if IME has uncommitted text
    preedit_width = 0
    if @ime && @ime.preedit.bytesize > 0
      cursor_display_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x)
      preedit_col = @prompt_width + cursor_display_col
      preedit_row = @input_start_row + @buffer.cursor_y
      max_preedit = Console::COLS - preedit_col
      if max_preedit > 0
        visible = Editor.display_slice(@ime.preedit, 0, max_preedit)
        if visible && visible.bytesize > 0
          DVI::Text.put_string(preedit_col, preedit_row, visible, InputMethod::PREEDIT_ATTR)
          preedit_width = Editor.display_width(visible)
        end
      end
    end

    # Draw candidate list on the row below input
    if @ime && @ime.candidates
      cand_row = @input_start_row + line_count
      @console.clear_line(cand_row)
      cand_text = ""
      @ime.candidates.each_with_index do |c, ci|
        break if ci >= 7
        cand_text += " " if ci > 0
        cand_text += "#{ci + 1}:#{c}"
      end
      visible = Editor.display_slice(cand_text, 0, Console::COLS)
      DVI::Text.put_string(0, cand_row, visible, InputMethod::CANDIDATE_ATTR) if visible
    end

    # Position cursor (after preedit if present)
    cursor_display_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x)
    screen_col = @prompt_width + cursor_display_col + preedit_width
    screen_row = @input_start_row + @buffer.cursor_y

    # Clamp cursor within screen
    screen_col = Console::COLS - 1 if screen_col >= Console::COLS
    @console.move_to(screen_col, screen_row)
    @console.show_cursor
  end

  # Draw a command line with app name highlighted in sky blue
  # app_name_len: byte length of the app name portion
  def draw_command_line(col, row, line, app_name_len, max_width)
    return unless line && line.bytesize > 0

    app_part = Editor.display_slice(line, 0, max_width)
    return unless app_part

    if app_name_len > 0 && app_name_len <= line.bytesize
      name = line.byteslice(0, app_name_len).to_s
      rest = line.byteslice(app_name_len, line.bytesize - app_name_len).to_s
      name_width = Editor.display_width(name)
      if name_width <= max_width
        DVI::Text.put_string(col, row, name, 0xC0) # palette 12 (sky blue)
        if rest.bytesize > 0
          rest_visible = Editor.display_slice(rest, 0, max_width - name_width)
          DVI::Text.put_string(col + name_width, row, rest_visible, 0xF0) if rest_visible # palette 15 (white)
        end
        return
      end
    end

    DVI::Text.put_string(col, row, app_part, 0xF0)
  end

  def feed
    @console.hide_cursor
    output_row = @input_start_row + @buffer.lines.length
    if output_row >= Console::ROWS
      scroll = output_row - Console::ROWS + 1
      @console.scroll_up(scroll)
      output_row = Console::ROWS - 1
    end
    @console.move_to(0, output_row)
  end
end
