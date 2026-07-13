# Hardware stubs for host tests. Loaded into the target VM (picoruby)
# before each test file, replacing the board's C modules so rootfs
# scripts run unmodified. Tests control time through Machine.millis=.

module Machine
  def self.board_millis
    $machine_millis || 0
  end

  def self.millis=(ms)
    $machine_millis = ms
  end
end

# DVI text mode stub for Console. Models the runtime grid dimensions
# (set_resolution switches 106x37 and 53x18 like the driver) and stores
# per-cell attributes for cursor rendering. Cell text is not modeled.
class DVI
  TEXT_MODE = 1
  GRAPHICS_MODE = 0

  def self.set_mode(mode); end

  def self.wait_vsync; end

  class Text
    COLS = 106
    ROWS = 37

    def self.cols
      $dvi_text_cols || COLS
    end

    def self.rows
      $dvi_text_rows || ROWS
    end

    def self.set_resolution(width, height)
      if width == 640 && height == 480
        $dvi_text_cols = 106
        $dvi_text_rows = 37
      elsif width == 320 && height == 240
        $dvi_text_cols = 53
        $dvi_text_rows = 18
      else
        raise ArgumentError, "resolution must be 640x480 or 320x240"
      end
    end

    def self.put_char(col, row, ch, attr); end
    def self.put_string(col, row, str, attr); end
    def self.clear(attr); $dvi_text_attrs = {}; end
    def self.clear_line(row, attr); end
    def self.clear_range(col, row, width, attr); end
    def self.scroll_up(lines, attr); end
    def self.scroll_down(lines, attr); end
    def self.commit; end

    def self.get_attr(col, row)
      ($dvi_text_attrs || {})[col * 256 + row] || 0xF0
    end

    def self.set_attr(col, row, attr)
      $dvi_text_attrs ||= {}
      $dvi_text_attrs[col * 256 + row] = attr
    end

    # Opaque line snapshots for the scrollback buffer.
    class Line; end

    def self.read_line(row)
      Line.new
    end

    def self.write_line(row, line); end
  end
end

# Editor display-width helper used by Console#put_char. The real module
# comes from the editor gem; tests only need the narrow/wide split.
module Editor
  def self.char_display_width(ch)
    ch.bytesize == 1 ? 1 : 2
  end
end

# Render a hap list as comparable strings: "whole|part|value" with
# fraction times as n/d. Keeps expectations readable in assert_equal.
def hap_sigs(haps)
  result = []
  i = 0
  while i < haps.length
    hap = haps[i]
    i += 1
    whole = hap.whole ? "#{frac_s(hap.whole.begin_time)}..#{frac_s(hap.whole.end_time)}" : "nil"
    part = "#{frac_s(hap.part.begin_time)}..#{frac_s(hap.part.end_time)}"
    result << "#{whole}|#{part}|#{hap.value.inspect}"
  end
  result
end

def frac_s(fraction)
  "#{fraction.num}/#{fraction.den}"
end
