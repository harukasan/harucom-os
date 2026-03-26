# Console: DVI::Text based text output with cursor management
#
# Provides a terminal-like text surface on DVI text mode.
# Compatible with $stdout (responds to puts, print, write, flush).
# All output is mirrored to UART via the original STDOUT.
# Supports scrollback buffer for viewing past output with PageUp/PageDown.
# Supports ANSI SGR escape sequences for color and bold.

class Console
  COLS = DVI::Text::COLS
  ROWS = DVI::Text::ROWS
  DEFAULT_ATTR = 0xF0 # white on black
  SCROLLBACK_MAX = 200

  # ANSI SGR escape sequence constants.
  #
  #   puts "#{Console::RED}Error:#{Console::RESET} something went wrong"
  #   puts "#{Console::BOLD}#{Console::YELLOW}Warning:#{Console::RESET} check"
  #
  RESET   = "\e[0m"
  BOLD    = "\e[1m"

  BLACK   = "\e[30m"
  RED     = "\e[31m"
  GREEN   = "\e[32m"
  YELLOW  = "\e[33m"
  BLUE    = "\e[34m"
  MAGENTA = "\e[35m"
  CYAN    = "\e[36m"
  WHITE   = "\e[37m"

  BRIGHT_BLACK   = "\e[90m"
  BRIGHT_RED     = "\e[91m"
  BRIGHT_GREEN   = "\e[92m"
  BRIGHT_YELLOW  = "\e[93m"
  BRIGHT_BLUE    = "\e[94m"
  BRIGHT_MAGENTA = "\e[95m"
  BRIGHT_CYAN    = "\e[96m"
  BRIGHT_WHITE   = "\e[97m"

  BG_BLACK   = "\e[40m"
  BG_RED     = "\e[41m"
  BG_GREEN   = "\e[42m"
  BG_YELLOW  = "\e[43m"
  BG_BLUE    = "\e[44m"
  BG_MAGENTA = "\e[45m"
  BG_CYAN    = "\e[46m"
  BG_WHITE   = "\e[47m"

  # ANSI standard color to palette index mapping.
  # Indices 0-7 match the standard VGA palette order.
  ANSI_COLOR_TABLE = [0, 4, 2, 6, 1, 5, 3, 7].freeze

  def initialize(attr: DEFAULT_ATTR)
    @col = 0
    @row = 0
    @default_attr = attr
    @attr = attr
    @bold = false
    @cursor_visible = false
    @uart = STDOUT
    @scrollback = []
    @scroll_offset = 0
    @viewport_snapshot = nil
    @esc_state = :normal
    @esc_buf = ""
    clear
  end

  attr_reader :col, :row, :attr, :scroll_offset

  # $stdout compatible methods

  def write(str)
    s = str.to_s
    @uart.write(s)
    s.each_char { |ch| put_char(ch) }
    s.bytesize
  end

  def print(*args)
    if args.empty?
      write($_) if $_
    else
      args.each { |a| write(a.to_s) }
    end
    nil
  end

  def puts(*args)
    if args.empty?
      write("\n")
    else
      args.each do |a|
        s = a.to_s
        write(s)
        write("\n") unless s.end_with?("\n")
      end
    end
    nil
  end

  def flush
    nil
  end

  # Cursor display (attribute inversion)

  def show_cursor
    return if @cursor_visible
    return if @col >= COLS
    a = DVI::Text.get_attr(@col, @row)
    DVI::Text.set_attr(@col, @row, ((a & 0x0F) << 4) | (a >> 4))
    @cursor_visible = true
  end

  def hide_cursor
    return unless @cursor_visible
    return if @col >= COLS
    a = DVI::Text.get_attr(@col, @row)
    DVI::Text.set_attr(@col, @row, ((a & 0x0F) << 4) | (a >> 4))
    @cursor_visible = false
  end

  # Low-level output

  def put_char(ch)
    case @esc_state
    when :escape
      if ch == "["
        @esc_state = :csi
        @esc_buf = ""
      else
        @esc_state = :normal
      end
      return
    when :csi
      if ch == "m"
        apply_sgr(@esc_buf)
        @esc_state = :normal
      elsif ch >= "0" && ch <= "9" || ch == ";"
        @esc_buf << ch
      else
        # Unknown CSI sequence, discard
        @esc_state = :normal
      end
      return
    end

    if ch == "\e"
      @esc_state = :escape
      return
    end
    if ch == "\n"
      newline
      return
    end
    if ch == "\t"
      spaces = 2 - (@col % 2)
      spaces.times { put_char(" ") }
      return
    end

    width = Editor.char_display_width(ch)
    newline if @col + width > COLS

    DVI::Text.put_string(@col, @row, ch, effective_attr)
    @col += width
  end

  def newline
    @col = 0
    @row += 1
    if @row >= ROWS
      scroll_up
      @row = ROWS - 1
    end
  end

  # Scrolling with scrollback buffer

  def scroll_up(lines = 1)
    if @scroll_offset == 0
      lines.times do |i|
        @scrollback.push(DVI::Text.read_line(i))
      end
      @scrollback.shift while @scrollback.length > SCROLLBACK_MAX
    end
    DVI::Text.scroll_up(lines, @attr)
  end

  # Scrollback navigation

  def scroll_back(lines = 1)
    return if @scrollback.empty?
    if @scroll_offset == 0
      save_viewport
    end
    @scroll_offset += lines
    max = @scrollback.length
    @scroll_offset = max if @scroll_offset > max
    render_scrollback
  end

  def scroll_forward(lines = 1)
    return if @scroll_offset == 0
    @scroll_offset -= lines
    if @scroll_offset <= 0
      @scroll_offset = 0
      restore_viewport
    else
      render_scrollback
    end
  end

  # Screen management

  def clear
    DVI::Text.clear(@attr)
    @col = 0
    @row = 0
  end

  def clear_line(row)
    DVI::Text.clear_line(row, @attr)
  end

  def clear_to_end_of_line
    DVI::Text.clear_range(@col, @row, COLS - @col, @attr)
  end

  # Cursor positioning

  def move_to(col, row)
    was_visible = @cursor_visible
    hide_cursor if was_visible
    @col = col
    @row = row
    show_cursor if was_visible
  end

  # Direct screen access (does not move cursor)

  def put_string_at(col, row, str, attr = @attr)
    DVI::Text.put_string(col, row, str, attr)
  end

  # VBlank sync

  def commit
    DVI::Text.commit
  end

  # Effective attribute with bold applied.
  # Bold shifts foreground to bright range (index + 8) if in 0-7.
  def effective_attr
    if @bold
      fg = (@attr >> 4) & 0x0F
      fg |= 0x08 if fg < 8
      (fg << 4) | (@attr & 0x0F)
    else
      @attr
    end
  end

  private

  # Apply SGR (Select Graphic Rendition) parameters to @attr.
  # Supports: 0 (reset), 1 (bold), 22 (normal intensity),
  # 30-37/90-97 (foreground), 39 (default foreground),
  # 40-47/100-107 (background), 49 (default background).
  def apply_sgr(buf)
    params = if buf.empty?
      [0]
    else
      buf.split(";").map { |s| s.to_i }
    end
    params.each do |p|
      case p
      when 0
        @attr = @default_attr
        @bold = false
      when 1
        @bold = true
      when 22
        @bold = false
      when 30..37
        fg = ANSI_COLOR_TABLE[p - 30]
        @attr = (fg << 4) | (@attr & 0x0F)
      when 39
        @attr = (@default_attr & 0xF0) | (@attr & 0x0F)
        @bold = false
      when 40..47
        bg = ANSI_COLOR_TABLE[p - 40]
        @attr = (@attr & 0xF0) | bg
      when 49
        @attr = (@attr & 0xF0) | (@default_attr & 0x0F)
      when 90..97
        fg = ANSI_COLOR_TABLE[p - 90] | 0x08
        @attr = (fg << 4) | (@attr & 0x0F)
      when 100..107
        bg = ANSI_COLOR_TABLE[p - 100] | 0x08
        @attr = (@attr & 0xF0) | bg
      end
    end
  end

  def save_viewport
    @viewport_snapshot = []
    ROWS.times { |r| @viewport_snapshot.push(DVI::Text.read_line(r)) }
  end

  def restore_viewport
    @viewport_snapshot.each_with_index do |line, r|
      DVI::Text.write_line(r, line)
    end
    @viewport_snapshot = nil
    DVI::Text.commit
  end

  def render_scrollback
    base = @scrollback.length - @scroll_offset
    ROWS.times do |screen_row|
      buf_index = base + screen_row
      if buf_index >= 0 && buf_index < @scrollback.length
        DVI::Text.write_line(screen_row, @scrollback[buf_index])
      else
        DVI::Text.clear_line(screen_row, @attr)
      end
    end
    DVI::Text.commit
  end
end
