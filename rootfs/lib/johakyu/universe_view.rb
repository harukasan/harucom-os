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
# Row layout, relative to `top`, sized from the running rig (rows):
#   0      [johakyu] |cycle bar| cyc/bpm and scheduler stats
#   1..    one attribute readback row per fixture (capped)
#   next.. universe channel grid rows (capped to the first channels)
#   last   separator line
# Without a rig only the clock row is shown, so the app doubles as an
# audio-only sequencer with the editor taking the rest of the screen.

require "johakyu/fixture"

module Johakyu
  class UniverseView
    # Height in rows for the current rig; the app lays the editor out
    # below this.
    attr_reader :rows

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

    # Rebuild the patch-dependent layout (fixture rows, channel grid
    # extent, and the view height) from the running rig. Call after a
    # patch swap, then reset to repaint. Kept out of reset so
    # scrolling, which resets every frame it shifts, does not
    # reallocate the layout.
    def repatch
      # Caps keep a large rig from squeezing the editor out; the grid
      # shows the first rows worth of channels.
      cap = Console.rows >= 30 ? 4 : 2
      @cells_per_row = Console.cols / 8

      # Fixture rows: [name, [[attribute, channel, label_x, value_x,
      # last_drawn], ...]]
      @fixture_rows = []
      names = Johakyu.patch.fixture_names
      i = 0
      while i < names.length && @fixture_rows.length < cap
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
      grid_rows = (@channel_count + @cells_per_row - 1) / @cells_per_row
      grid_rows = cap if grid_rows > cap
      @grid_rows = grid_rows
      @channel_display_count = @channel_count
      limit = @grid_rows * @cells_per_row
      @channel_display_count = limit if @channel_display_count > limit
      @grid_top = @top + 1 + @fixture_rows.length

      # Clock row, fixture rows, grid rows, and a closing separator
      # when a rig is patched; the clock row alone without one.
      if @channel_count > 0
        @rows = 1 + @fixture_rows.length + @grid_rows + 1
      else
        @rows = 1
      end
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
      while ch <= @channel_display_count
        x, y = channel_cell(ch)
        DVI::Text.put_string(x, y, format_3(ch) + ":", ATTR_NORMAL)
        ch += 1
      end
      if @channel_count > 0
        separator = ""
        i = 0
        while i < Console.cols
          separator = separator + "-"
          i += 1
        end
        DVI::Text.put_string(0, @top + @rows - 1, separator, ATTR_NORMAL)
      end

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
      while ch <= @channel_display_count
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
      [col * 8, @grid_top + row]
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
