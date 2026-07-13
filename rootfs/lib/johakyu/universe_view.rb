# Johakyu universe view: the top status area of the live coding UI
# (research 06). Shows the cycle bar, scheduler health, per-fixture
# attribute readbacks, and the raw universe channel grid. A channel
# whose value changed is drawn inverted for a moment, so the audience
# can see DMX as an array of channel number and value.
#
# Drawing is differential: every cell caches its last drawn value and
# only changed cells reach DVI::Text. Value strings come from a
# precomputed 256-entry table, so the steady-state draw path allocates
# nothing (the scheduler runs in the same loop; string churn here
# would turn into GC pauses there).
#
# Row layout, relative to `top`:
#   0  [johakyu] |cycle bar| cyc/bpm and scheduler stats
#   1  fixture 1 attribute readbacks
#   2  fixture 2 attribute readbacks
#   3  universe channels, first row
#   4  universe channels, second row
#   5  separator line

require "johakyu/fixture"

module Johakyu
  class UniverseView
    ROWS = 6

    ATTR_NORMAL  = 0xF0
    ATTR_TITLE   = 0x1F
    ATTR_CHANGED = 0x0F

    BAR_STEPS = 16
    HIGHLIGHT_MS = 250
    DRAW_INTERVAL_MS = 30
    STATS_INTERVAL_MS = 500

    FIXTURE_ATTRIBUTES = [:pan, :tilt, :dimmer, :strobe, :color, :gobo, :prism]

    def initialize(session, top: 0)
      @session = session
      @top = top

      # "000".."255" built once; index by channel value.
      @value_strings = []
      i = 0
      while i < 256
        @value_strings << format_3(i)
        i += 1
      end

      # Cycle bar: one prebuilt string per cursor position.
      @bar_strings = []
      s = 0
      while s < BAR_STEPS
        bar = ""
        c = 0
        while c < BAR_STEPS
          bar = bar + (c <= s ? "#" : ".")
          c += 1
        end
        @bar_strings << bar
        s += 1
      end

      @prev_values = Array.new(513, -1)
      @changed_ms = Array.new(513, 0)
      @prev_step = -1
      @prev_cycle = -1
      @prev_bpm = 0
      @last_draw_ms = 0
      @last_stats_ms = 0

      repatch
    end

    # Rebuild the patch-dependent layout (fixture rows and the channel
    # grid extent) from the running rig. Call after a patch swap, then
    # reset to repaint. Kept out of reset so scrolling, which resets
    # every frame it shifts, does not reallocate the layout.
    def repatch
      # Fixture rows: [name, [[attribute, channel, label_x, value_x,
      # last_drawn], ...]]
      @fixture_rows = []
      names = Johakyu.patch.fixture_names
      i = 0
      while i < names.length && @fixture_rows.length < 2
        name = names[i]
        i += 1
        fixture = Johakyu.patch[name]
        fields = []
        x = 4
        j = 0
        while j < FIXTURE_ATTRIBUTES.length
          attribute = FIXTURE_ATTRIBUTES[j]
          j += 1
          channel = begin
            fixture.channel(attribute)
          rescue ArgumentError
            nil
          end
          next unless channel
          # "pan:255 " label + value; value_x points at the digits.
          # The trailing slot caches the last drawn value.
          label_x = x
          value_x = x + attribute.to_s.length + 1
          fields << [attribute, channel, label_x, value_x, -1]
          x = value_x + 4
        end
        @fixture_rows << [name, fields]
      end

      @channel_count = Johakyu.patch.max_channel
      @cells_per_row = Console.cols / 8
    end

    # Draw the static furniture and force every cell to repaint on the
    # next draw. Call once after the screen is cleared.
    def reset
      DVI::Text.put_string(0, @top, "[johakyu]", ATTR_TITLE)
      i = 0
      while i < @fixture_rows.length
        row = @fixture_rows[i]
        y = @top + 1 + i
        DVI::Text.put_string(0, y, row[0].to_s, ATTR_TITLE)
        fields = row[1]
        j = 0
        while j < fields.length
          field = fields[j]
          j += 1
          DVI::Text.put_string(field[2], y, field[0].to_s + ":", ATTR_NORMAL)
        end
        i += 1
      end
      # Channel grid labels ("001:") drawn once.
      ch = 1
      while ch <= @channel_count
        x, y = channel_cell(ch)
        DVI::Text.put_string(x, y, format_3(ch) + ":", ATTR_NORMAL)
        ch += 1
      end
      separator = ""
      i = 0
      while i < Console.cols
        separator = separator + "-"
        i += 1
      end
      DVI::Text.put_string(0, @top + 5, separator, ATTR_NORMAL)

      i = 0
      while i < @prev_values.length
        @prev_values[i] = -1
        @changed_ms[i] = 0
        i += 1
      end
      i = 0
      while i < @fixture_rows.length
        fields = @fixture_rows[i][1]
        j = 0
        while j < fields.length
          fields[j][4] = -1
          j += 1
        end
        i += 1
      end
      @prev_step = -1
      @prev_cycle = -1
      @prev_bpm = 0
      @last_draw_ms = 0
      @last_stats_ms = 0
    end

    # Differential update. Call every loop iteration; rate-limited
    # internally so the scheduler keeps its loop cadence.
    def draw
      now = Machine.board_millis
      return if now - @last_draw_ms < DRAW_INTERVAL_MS
      @last_draw_ms = now

      draw_clock_row(now)
      draw_fixture_rows(now)
      draw_channel_grid(now)
    end

    private

    def draw_clock_row(now)
      position = @session.clock.position
      cycle = position.to_i
      step = ((position - cycle) * BAR_STEPS).to_i
      step = BAR_STEPS - 1 if step > BAR_STEPS - 1
      if step != @prev_step
        @prev_step = step
        DVI::Text.put_string(10, @top, @bar_strings[step], ATTR_NORMAL)
      end
      if cycle != @prev_cycle || @session.clock.bpm != @prev_bpm
        @prev_cycle = cycle
        @prev_bpm = @session.clock.bpm
        DVI::Text.put_string(27, @top, "cyc #{cycle} bpm #{@prev_bpm.to_i}   ", ATTR_NORMAL)
      end
      if now - @last_stats_ms >= STATS_INTERVAL_MS
        @last_stats_ms = now
        scheduler = @session.scheduler
        tick_avg_us = (scheduler.tick_ms_average * 1000).to_i
        DVI::Text.put_string(44, @top,
          "tick #{tick_avg_us}us mx #{scheduler.tick_ms_max} st #{scheduler.stage_ms_max} lt #{scheduler.fire_delay_ms_max}ms   ",
          ATTR_NORMAL)
      end
    end

    def draw_fixture_rows(_now)
      i = 0
      while i < @fixture_rows.length
        row = @fixture_rows[i]
        y = @top + 1 + i
        fields = row[1]
        j = 0
        while j < fields.length
          field = fields[j]
          j += 1
          value = DMX.get(field[1])
          if field[4] != value
            field[4] = value
            DVI::Text.put_string(field[3], y, @value_strings[value], ATTR_NORMAL)
          end
        end
        i += 1
      end
    end

    def draw_channel_grid(now)
      ch = 1
      while ch <= @channel_count
        value = DMX.get(ch)
        if value != @prev_values[ch]
          @prev_values[ch] = value
          @changed_ms[ch] = now
          x, y = channel_cell(ch)
          DVI::Text.put_string(x + 4, y, @value_strings[value], ATTR_CHANGED)
        elsif @changed_ms[ch] != 0 && now - @changed_ms[ch] >= HIGHLIGHT_MS
          @changed_ms[ch] = 0
          x, y = channel_cell(ch)
          DVI::Text.put_string(x + 4, y, @value_strings[value], ATTR_NORMAL)
        end
        ch += 1
      end
    end

    def channel_cell(ch)
      index = ch - 1
      row = index / @cells_per_row
      col = index % @cells_per_row
      [col * 8, @top + 3 + row]
    end

    def format_3(value)
      if value < 10
        "00#{value}"
      elsif value < 100
        "0#{value}"
      else
        "#{value}"
      end
    end
  end
end
