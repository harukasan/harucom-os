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

# DMX universe stub with a write log for timing assertions.
module DMX
  def self.reset
    $dmx_universe = nil
    $dmx_writes = nil
    $dmx_active_slots = nil
  end

  def self.active_slots=(count)
    $dmx_active_slots = count
  end

  def self.universe
    $dmx_universe ||= Array.new(513, 0)
  end

  def self.writes
    $dmx_writes ||= []
  end

  def self.set(channel, value)
    universe[channel] = value
    writes << [Machine.board_millis, channel, value]
  end

  def self.set_range(channel, values)
    i = 0
    while i < values.length
      set(channel + i, values[i])
      i += 1
    end
  end

  def self.get(channel)
    universe[channel]
  end

  def self.blackout
    ch = 1
    while ch <= 512
      universe[ch] = 0
      ch += 1
    end
  end
end

module PWMAudio
  SINE = 0
  SQUARE = 1
  TRIANGLE = 2
  SAWTOOTH = 3
end

# Records tone/stop calls with the stubbed time for assertions.
class FakeAudio
  attr_reader :events

  def initialize
    @events = []
  end

  def tone(channel, frequency, waveform: 0, volume: 15)
    @events << [:tone, Machine.board_millis, channel, frequency, volume]
  end

  def stop(channel)
    @events << [:stop, Machine.board_millis, channel]
  end

  def stop_all
  end

  def update
  end

  # Sample clock anchored to the stubbed millis at the engine rate, so
  # reservation math in tests resolves to target_ms * 50 exactly.
  def sample_clock
    Machine.board_millis * 50
  end

  def load_sample(slot, data)
    @loaded_samples ||= {}
    @loaded_samples[slot] = data
    true
  end

  def play_at(sample, channel, volume = 15, slot = nil)
    @events << [:play_at, sample, channel, volume, slot]
    true
  end

  def tones
    @events.select { |e| e[0] == :tone }
  end

  def stops
    @events.select { |e| e[0] == :stop }
  end

  def plays
    @events.select { |e| e[0] == :play_at }
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

# The shipped SHEHDS OFL definition, read from the repository so host
# tests exercise the same file the board loads from /data.
JOHAKYU_TEST_FIXTURE = "rootfs/data/dmx/fixtures/shehds_80w_led_spot_light.json"

# The bench rig: two SHEHDS units in 13ch mode (s1 = 1, s2 = 14) and
# the :all group, built through the OFL loader like a live script.
def johakyu_test_patch
  personality = Johakyu.personality(JOHAKYU_TEST_FIXTURE, "13ch")
  patch = Johakyu::Patch.new
  patch.add(:s1, personality, base: 1)
  patch.add(:s2, personality, base: 14)
  patch.group(:all, :s1, :s2)
  patch
end
