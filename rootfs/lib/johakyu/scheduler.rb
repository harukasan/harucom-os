# Johakyu scheduler: schedule-ahead query loop with two sink kinds.
#
# tick() runs at the main loop rate (about 60 Hz), queries every track
# over [last, now + lookahead), and converts each discrete onset into a
# pending event stamped with its exact target time in board_millis.
# pump() fires pending events whose time has come; call it every loop
# iteration. Continuous tracks (signals) are sampled once per tick and
# written immediately, since DMX output is quantized to 40 Hz frames
# anyway.
#
# Live replacement is quantized: rebinding an existing track stores the
# new pattern and applies it at the next integer cycle boundary, so
# edits land musically. A track whose query raises falls back to its
# last good pattern instead of silencing the whole scheduler.

require "johakyu/pattern"

module Johakyu
  class Scheduler
    LOOKAHEAD_MS = 50

    attr_reader :tick_count, :tick_ms_total, :tick_ms_max, :fired_count

    def initialize(clock)
      @clock = clock
      @tracks = {}
      @order = []
      @pending = []
      @last_position = nil
      @tick_count = 0
      @tick_ms_total = 0
      @tick_ms_max = 0
      @fired_count = 0
      @errors = {}
    end

    # Bind a discrete pattern. The sink receives (value, at_ms) for each
    # onset. Rebinding an existing name swaps at the next cycle boundary.
    def bind(name, pattern, &sink)
      add_track(name, pattern, false, sink)
    end

    # Bind a continuous pattern. The sink receives the current value
    # once per tick.
    def bind_continuous(name, pattern, &sink)
      add_track(name, pattern, true, sink)
    end

    def remove(name)
      if @tracks.delete(name)
        @order.delete(name)
      end
    end

    def clear
      @tracks = {}
      @order = []
      @pending = []
    end

    def track_names
      @order
    end

    def pending_count
      @pending.length
    end

    def last_error(name)
      @errors[name]
    end

    # Advance the query window and stage upcoming events.
    def tick
      started_ms = Machine.board_millis
      now_position = @clock.position
      horizon = Fraction.of(now_position + LOOKAHEAD_MS / @clock.ms_per_cycle)
      @last_position ||= Fraction.of(now_position)
      last = @last_position
      return if horizon <= last

      i = 0
      while i < @order.length
        track = @tracks[@order[i]]
        i += 1
        next unless track
        begin
          if track[:continuous]
            sample_continuous(track, now_position)
          else
            query_track(track, last, horizon)
          end
        rescue => e
          name = track[:name]
          @errors[name] = "#{e.message} (#{e.class})"
          # Fall back to the last good pattern; if this was the last
          # good pattern itself, silence just this track.
          if track[:pattern].equal?(track[:last_good])
            track[:pattern] = Pattern.silence
          else
            track[:pattern] = track[:last_good]
          end
        end
      end

      @last_position = horizon
      elapsed = Machine.board_millis - started_ms
      @tick_count += 1
      @tick_ms_total += elapsed
      @tick_ms_max = elapsed if elapsed > @tick_ms_max
    end

    # Fire pending events that are due. Returns the number fired.
    def pump
      now = Machine.board_millis
      fired = 0
      i = 0
      while i < @pending.length
        event = @pending[i]
        if event[0] <= now
          @pending.delete_at(i)
          event[1].call(event[2], event[0])
          fired += 1
        else
          i += 1
        end
      end
      @fired_count += fired
      fired
    end

    # Average tick cost in ms over the whole run (R15 measurement).
    def tick_ms_average
      return 0.0 if @tick_count == 0
      @tick_ms_total.to_f / @tick_count
    end

    private

    def add_track(name, pattern, continuous, sink)
      track = @tracks[name]
      if track
        # Quantize the swap to the next integer cycle boundary.
        track[:next_pattern] = pattern
        track[:swap_at] = (@last_position || Fraction.of(@clock.position)).next_sam
        track[:sink] = sink
        track[:continuous] = continuous
      else
        @tracks[name] = {
          name: name,
          pattern: pattern,
          last_good: pattern,
          next_pattern: nil,
          swap_at: nil,
          continuous: continuous,
          sink: sink,
        }
        @order << name
      end
    end

    # Query one discrete track over [last, horizon), honoring a pending
    # quantized swap that falls inside the window.
    def query_track(track, last, horizon)
      swap_at = track[:swap_at]
      if swap_at && swap_at <= last
        apply_swap(track)
        swap_at = nil
      end
      if swap_at && swap_at < horizon
        stage_onsets(track, track[:pattern].query(TimeSpan.new(last, swap_at)))
        apply_swap(track)
        stage_onsets(track, track[:pattern].query(TimeSpan.new(swap_at, horizon)))
      else
        stage_onsets(track, track[:pattern].query(TimeSpan.new(last, horizon)))
      end
      track[:last_good] = track[:pattern]
    end

    def apply_swap(track)
      track[:pattern] = track[:next_pattern]
      track[:next_pattern] = nil
      track[:swap_at] = nil
    end

    def stage_onsets(track, haps)
      sink = track[:sink]
      i = 0
      while i < haps.length
        hap = haps[i]
        i += 1
        next unless hap.has_onset?
        at_ms = @clock.position_to_ms(hap.whole.begin_time).to_i
        @pending << [at_ms, sink, hap.value]
      end
    end

    # Sample a continuous track at the current position. EPSILON keeps
    # the span non-empty; signals sample at the span midpoint.
    EPSILON = Fraction.new(1, 3840)

    def sample_continuous(track, now_position)
      swap_at = track[:swap_at]
      if swap_at && swap_at <= now_position
        apply_swap(track)
      end
      t = Fraction.of(now_position)
      haps = track[:pattern].query(TimeSpan.new(t, t + EPSILON))
      if haps.length > 0
        track[:sink].call(haps[0].value, nil)
      end
      track[:last_good] = track[:pattern]
    end
  end
end
