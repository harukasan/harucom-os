# LineEditor: Reline-like line input on DVI text mode
#
# Provides readline and readmultiline methods using Console, Editor::Buffer,
# and Keyboard. Handles line editing, cursor rendering, and input area display.

class LineEditor
  def initialize(console:, keyboard:)
    @console = console
    @keyboard = keyboard
    @buffer = Editor::Buffer.new
    @prompt = "> "
    @prompt_cont = "> "
    @prompt_width = 2
    @input_start_row = 0
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

    loop do
      refresh
      @console.commit

      c = @keyboard.read_char
      unless c
        DVI.wait_vsync
        next
      end

      # Return to live view if scrolled back
      if @console.scroll_offset > 0
        case c
        when Keyboard::ENTER, Keyboard::BSPACE
          @console.scroll_forward(@console.scroll_offset)
        else
          @console.scroll_forward(@console.scroll_offset) if c.printable?
        end
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

    # Scroll if input area would exceed screen
    needed_rows = line_count
    available_rows = Console::ROWS - @input_start_row
    if needed_rows > available_rows
      scroll_amount = needed_rows - available_rows
      @console.scroll_up(scroll_amount)
      @input_start_row -= scroll_amount
      @input_start_row = 0 if @input_start_row < 0
    end

    # Tokenize input for syntax highlighting
    source = lines.join("\n")
    highlight_map = SyntaxHighlight.tokenize(source)
    hl_offsets = nil
    if highlight_map
      hl_offsets = []
      offset = 0
      lines.each { |l| hl_offsets.push(offset); offset += l.bytesize + 1 }
    end

    # Render each line
    max_line_width = Console::COLS - @prompt_width
    i = 0
    while i < line_count
      row = @input_start_row + i
      prompt = (i == 0) ? @prompt : @prompt_cont
      @console.clear_line(row)
      @console.put_string_at(0, row, prompt, @console.attr)
      if highlight_map && hl_offsets
        SyntaxHighlight.draw_line(@prompt_width, row, lines[i], highlight_map, hl_offsets[i] || 0, 0, max_line_width, @console.attr)
      else
        visible_text = Editor.display_slice(lines[i], 0, max_line_width)
        @console.put_string_at(@prompt_width, row, visible_text, @console.attr) if visible_text
      end
      i += 1
    end

    # Clear rows below input (remove stale content)
    clear_row = @input_start_row + line_count
    while clear_row < Console::ROWS
      @console.clear_line(clear_row)
      clear_row += 1
    end

    # Position cursor
    cursor_display_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x)
    screen_col = @prompt_width + cursor_display_col
    screen_row = @input_start_row + @buffer.cursor_y

    # Clamp cursor within screen
    screen_col = Console::COLS - 1 if screen_col >= Console::COLS
    @console.move_to(screen_col, screen_row)
    @console.show_cursor
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
