# LineEditor: Reline-like line input on DVI text mode
#
# Provides readline and readmultiline methods using Console, Editor::Buffer,
# and Keyboard. Handles line editing, cursor rendering, and input area display.

class LineEditor
  attr_accessor :highlight_proc

  # Key bindings local to the line editor. Defined here instead of in the
  # keyboard gem so adding them does not force a presym rebuild (this file is
  # loaded from the rootfs and compiled on device, so the symbols intern at
  # runtime).
  CTRL_A = Keyboard.key(:a, ctrl: true)
  CTRL_E = Keyboard.key(:e, ctrl: true)
  CTRL_O = Keyboard.key(:o, ctrl: true)

  STATUS_ATTR = 0x0F # black on white (inverted), for the status row prompt

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

      # Zoom toggle: Ctrl-Shift-'=' switches the console between 640x480
      # and 320x240 (2x scaled) text resolution. Checked before the IME
      # so the shortcut works while an input method is active.
      if c.match?(zoom_key_name, ctrl: true, shift: true)
        toggle_zoom
        next
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
      when CTRL_A
        @buffer.head
      when CTRL_E
        @buffer.tail
      when CTRL_O
        load_file_into_buffer
      when Keyboard::ENTER
        script = @buffer.dump.chomp
        if check.call(script)
          # Re-indent last line (e.g. de-indent end) before execution
          last_y = @buffer.cursor_y
          source = @buffer.lines.join("\n")
          result = RubySyntax.analyze(source)
          if result
            RubySyntax.reindent_line(@buffer, last_y, result.indent_level(last_y))
          end
          refresh
          @console.commit
          feed
          return script
        else
          @buffer.put(c.to_buffer_input)
          # Auto-indent: re-analyze and adjust indentation
          source = @buffer.lines.join("\n")
          result = RubySyntax.analyze(source)
          if result
            # Re-indent previous line (e.g. de-indent end/else/ensure)
            prev_y = @buffer.cursor_y - 1
            if prev_y >= 0
              RubySyntax.reindent_line(@buffer, prev_y, result.indent_level(prev_y))
            end
            # Indent new line
            level = result.indent_level(@buffer.cursor_y)
            @buffer.put("  " * level) if level > 0
          end
        end
      when Keyboard::PAGEUP
        @console.scroll_back(Console.rows - 1)
      when Keyboard::PAGEDOWN
        @console.scroll_forward(Console.rows - 1)
      when Keyboard::UP
        @buffer.put(c.to_buffer_input) if @buffer.cursor_y > 0
      when Keyboard::DOWN
        @buffer.put(c.to_buffer_input) if @buffer.cursor_y < @buffer.lines.length - 1
      when Keyboard::DELETE
        @buffer.delete
      else
        if c.printable?
          @buffer.put(c.to_s)
          # De-indent on space after keywords like when, elsif, rescue, in
          if c.to_s == " " && RubySyntax.should_dedent_on_space?(@buffer.current_line)
            source = @buffer.lines.join("\n")
            result = RubySyntax.analyze(source)
            if result
              RubySyntax.reindent_line(@buffer, @buffer.cursor_y, result.indent_level(@buffer.cursor_y))
            end
          end
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

    available_rows = Console.rows - @input_start_row
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
      result = RubySyntax.analyze(source)
      highlight_map = result && result.highlight_map
      hl_offsets = nil
      if highlight_map
        hl_offsets = []
        offset = 0
        lines.each { |l| hl_offsets.push(offset); offset += l.bytesize + 1 }
      end
    end

    # Render each line
    max_line_width = Console.cols - @prompt_width
    i = 0
    while i < line_count
      row = @input_start_row + i
      prompt = (i == 0) ? @prompt : @prompt_cont
      @console.clear_line(row)
      @console.put_string_at(0, row, prompt, @console.attr)
      if custom && i == 0
        draw_command_line(@prompt_width, row, lines[0], custom, max_line_width)
      elsif highlight_map && hl_offsets
        RubySyntax.draw_line(@prompt_width, row, lines[i], highlight_map, hl_offsets[i] || 0, 0, max_line_width, @console.attr)
      else
        visible_text = Editor.display_slice(lines[i], 0, max_line_width)
        @console.put_string_at(@prompt_width, row, visible_text, @console.attr) if visible_text
      end
      i += 1
    end

    # Clear up to (but not including) IME status row
    clear_limit = ime_active ? Console.rows - 1 : Console.rows

    # Clear rows below input up to (but not including) IME status row
    clear_row = @input_start_row + line_count
    while clear_row < clear_limit
      @console.clear_line(clear_row)
      clear_row += 1
    end

    # Draw IME mode indicator on last row
    if ime_active
      label = @ime.mode_label
      ime_row = Console.rows - 1
      @console.clear_line(ime_row)
      label_col = Console.cols - Editor.display_width(label)
      DVI::Text.put_string(label_col, ime_row, label, InputMethod::PREEDIT_ATTR)
    end

    # Draw preedit overlay if IME has uncommitted text
    preedit_width = 0
    if @ime && @ime.preedit.bytesize > 0
      cursor_display_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x)
      preedit_col = @prompt_width + cursor_display_col
      preedit_row = @input_start_row + @buffer.cursor_y
      max_preedit = Console.cols - preedit_col
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
      visible = Editor.display_slice(cand_text, 0, Console.cols)
      DVI::Text.put_string(0, cand_row, visible, InputMethod::CANDIDATE_ATTR) if visible
    end

    # Position cursor (after preedit if present)
    cursor_display_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x)
    screen_col = @prompt_width + cursor_display_col + preedit_width
    screen_row = @input_start_row + @buffer.cursor_y

    # Clamp cursor within screen
    screen_col = Console.cols - 1 if screen_col >= Console.cols
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
    if output_row >= Console.rows
      scroll = output_row - Console.rows + 1
      @console.scroll_up(scroll)
      output_row = Console.rows - 1
    end
    @console.move_to(0, output_row)
  end

  # Key name produced by physical Ctrl-Shift-'='. The Key name follows the
  # layout-applied character: "+" on the US layout, "=" on JIS (JIS types
  # '=' as Shift-'-').
  def zoom_key_name
    ENV["KEYBOARD_LAYOUT"] == "jis" ? :"=" : :+
  end

  # Toggle between the native and the 2x scaled console resolution. The
  # console is reset because its contents do not fit the new grid; refresh
  # then redraws the prompt and the current input buffer from row 0.
  def toggle_zoom
    if DVI::Text.cols == DVI::Text::COLS
      DVI::Text.set_resolution(320, 240)
    else
      DVI::Text.set_resolution(640, 480)
    end
    @console.reset
    @input_start_row = 0
  end

  # Load a text file into the input buffer as multi-line input. Prompts for a
  # path on the status row, then replaces the current buffer with the file's
  # contents so the user can edit it in place and run it with Enter.
  def load_file_into_buffer
    path = prompt_status_line("Open file: ")
    return if path.nil? || path.bytesize == 0

    unless File.file?(path)
      show_status_message("File not found: #{path}")
      return
    end

    content = File.open(path, "r") { |f| f.read }
    unless content
      show_status_message("Cannot read: #{path}")
      return
    end

    lines = content.split("\n")
    # Strip a trailing CR so a file with CRLF line endings does not leave a
    # stray control character at the end of every line.
    i = 0
    while i < lines.length
      line = lines[i]
      if line.bytesize > 0 && line.getbyte(line.bytesize - 1) == 0x0D
        lines[i] = line.byteslice(0, line.bytesize - 1).to_s
      end
      i += 1
    end
    lines = [""] if lines.empty?

    # Discard any half-typed IME composition so it does not leak into the
    # loaded buffer.
    @ime.reset if @ime
    # @buffer.clear leaves the cursor at the top. Keep it there rather than
    # moving to the end: a file taller than the screen would otherwise put the
    # cursor off-screen, since the input area is rendered from the top.
    @buffer.clear
    @buffer.lines = lines
    @needs_refresh = true
  end

  # Read a single line of text on the status row (bottom of the screen).
  # Returns the entered string, or nil if cancelled with Escape.
  def prompt_status_line(label)
    input = ""
    row = Console.rows - 1
    @console.hide_cursor
    loop do
      display = " #{label}#{input}"
      padding = Console.cols - Editor.display_width(display)
      display += " " * padding if padding > 0
      @console.put_string_at(0, row, Editor.display_slice(display, 0, Console.cols), STATUS_ATTR)
      @console.commit

      c = @keyboard.read_char
      unless c
        DVI.wait_vsync
        next
      end

      case c
      when Keyboard::ENTER
        return input
      when Keyboard::ESCAPE
        return nil
      when Keyboard::BSPACE
        if input.bytesize > 0
          input = input.byteslice(0, Editor.prev_char_byte_pos(input, input.bytesize)).to_s
        end
      else
        input += c.to_s if c.printable?
      end
    end
  end

  # Draw a one-line message on the status row. Clearing @needs_refresh keeps the
  # message on screen until the next keystroke (which sets @needs_refresh again
  # and redraws over it), instead of the loop erasing it on the next frame.
  def show_status_message(msg)
    row = Console.rows - 1
    @console.clear_line(row)
    @console.put_string_at(0, row, Editor.display_slice(" #{msg}", 0, Console.cols), STATUS_ATTR)
    @console.commit
    @needs_refresh = false
  end
end
