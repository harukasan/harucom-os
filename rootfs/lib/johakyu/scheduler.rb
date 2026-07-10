# Johakyu scheduler: chunked schedule-ahead staging.
#
# Tracks are staged in cycle-sized chunks: each track keeps a
# staged_until position, and tick() advances at most one track per call
# (the most urgent one), converting every onset in the chunk into a
# pending event stamped with its target board_millis. Querying per
# chunk instead of per tick keeps the mruby query cost (Fraction/Hap
# allocation, GC pressure) off the main loop; a typical tick does no
# query work at all, so pump() fires events with loop-iteration jitter
# only. pump() must be called every loop iteration. Continuous signals
# do not reach the scheduler: the control layer discretizes them
# (segment) or samples them at event times (structure from left).
#
# Live replacement is quantized: rebinding an existing track applies at
# the next integer cycle boundary. Events already staged past that
# boundary are dropped and restaged from the new pattern, so edits land
# musically. A track whose query raises falls back to its last good
# pattern instead of silencing the whole scheduler.

require "johakyu/pattern"

module Johakyu
  class Scheduler
    # Keep at least this many cycles staged ahead, adding one chunk at
    # a time. The minimum must cover several loop iterations so all
    # tracks get their staging turn before events fall due. The
    # threshold compares as Float so an idle tick allocates nothing.
    # Quarter-cycle chunks halve the fixed per-query overhead compared
    # to smaller chunks. The stall a staging tick can cause is roughly
    # one chunk's query cost; the dispatcher's RESERVE_LEAD_MS absorbs
    # it, so sounds and lights still land on time (see dsl.rb).
    STAGE_AHEAD_MIN = 0.25
    STAGE_CHUNK = Fraction.new(1, 4)

    # Staging yields to imminent events: when a pending event fires
    # within this many ms, the tick skips staging so a long query does
    # not block pump and fire that event late. Staging only yields
    # while the track is staged at least the minimum runway ahead, so
    # dense events cannot starve staging.
    STAGE_DEFER_EVENT_MS = 30
    STAGE_DEFER_MIN_AHEAD = 0.05

    attr_reader :tick_count, :tick_ms_total, :tick_ms_max, :fired_count,
                :fire_delay_ms_max, :stage_ms_max

    def initialize(clock)
      @clock = clock
      @tracks = {}
      @order = []
      @pending = []
      @tick_count = 0
      @tick_ms_total = 0
      @tick_ms_max = 0
      @fired_count = 0
      @fire_delay_ms_max = 0
      @stage_ms_max = 0
      @errors = {}
    end

    # Bind a pattern. The sink receives (value, at_ms) for each onset.
    # Rebinding an existing name swaps at the next cycle boundary.
    # latency_ms fires the sink early of the musical target, e.g. to
    # leave room for a sample-accurate reservation on a slower output
    # path.
    def bind(name, pattern, latency_ms: 0, &sink)
      add_track(name, pattern, sink, latency_ms)
    end

    # Change the output latency compensation of a track. Call restage
    # afterwards so already staged events pick up the new offset.
    def set_latency(name, latency_ms)
      track = @tracks[name]
      track[:latency_ms] = latency_ms if track
    end

    def remove(name)
      if @tracks.delete(name)
        @order.delete(name)
        drop_pending(name, 0)
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

    # Reset the performance counters (averages and high-water marks).
    # The demo calls this on preset switches so the numbers describe
    # the current preset instead of the whole run.
    def reset_stats
      @tick_count = 0
      @tick_ms_total = 0
      @tick_ms_max = 0
      @fired_count = 0
      @fire_delay_ms_max = 0
      @stage_ms_max = 0
    end

    # Drop staged events and stage again from the current position.
    # Call after a tempo change: staged target times were computed with
    # the old tempo and would fire off the new grid.
    def restage
      @pending = []
      position = Fraction.of(@clock.position)
      i = 0
      while i < @order.length
        track = @tracks[@order[i]]
        i += 1
        next if track.nil?
        track[:staged_until] = position
      end
    end

    # Advance the most urgent track by one staging chunk when it runs
    # low.
    def tick
      started_ms = Machine.board_millis
      now_position = @clock.position

      urgent = nil
      i = 0
      while i < @order.length
        track = @tracks[@order[i]]
        i += 1
        next unless track
        if urgent.nil? || track[:staged_until] < urgent[:staged_until]
          urgent = track
        end
      end

      if urgent && urgent[:staged_until].to_f < now_position + STAGE_AHEAD_MIN
        unless defer_staging?(urgent, now_position, started_ms)
          begin
            stage_chunk(urgent)
          rescue => e
            track_failed(urgent, e)
          end
        end
      end

      elapsed = Machine.board_millis - started_ms
      @tick_count += 1
      @tick_ms_total += elapsed
      @tick_ms_max = elapsed if elapsed > @tick_ms_max
    end

    # Fire pending events that are due. Returns the number fired.
    # fire_delay_ms_max records how late events fire relative to their
    # target time; large values point at loop stalls (GC, slow drawing).
    def pump
      now = Machine.board_millis
      fired = 0
      i = 0
      while i < @pending.length
        event = @pending[i]
        if event[0] <= now
          @pending.delete_at(i)
          delay = now - event[0]
          @fire_delay_ms_max = delay if delay > @fire_delay_ms_max
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

    def add_track(name, pattern, sink, latency_ms)
      track = @tracks[name]
      if track
        # Quantize the swap to the next integer cycle boundary. Events
        # already staged past the boundary belong to the old pattern;
        # drop them so the new pattern fills that range instead.
        swap_at = Fraction.of(@clock.position).next_sam
        if track[:staged_until] > swap_at
          drop_pending(name, @clock.position_to_ms(swap_at).to_i - track[:latency_ms])
          track[:staged_until] = swap_at
        end
        track[:next_pattern] = pattern
        track[:swap_at] = swap_at
        track[:sink] = sink
        track[:latency_ms] = latency_ms
      else
        track = {
          name: name,
          pattern: pattern,
          last_good: pattern,
          next_pattern: nil,
          swap_at: nil,
          sink: sink,
          latency_ms: latency_ms,
          staged_until: Fraction.of(@clock.position),
        }
        @tracks[name] = track
        @order << name
        # Stage the first chunk right away so a fresh track plays its
        # first events on time instead of waiting for a staging turn.
        begin
          stage_chunk(track)
        rescue => e
          track_failed(track, e)
        end
      end
    end

    # True when staging should wait a tick: an event is about to fire
    # and the track has enough runway to stage later.
    def defer_staging?(track, now_position, now_ms)
      return false if track[:staged_until].to_f <= now_position + STAGE_DEFER_MIN_AHEAD
      i = 0
      while i < @pending.length
        return true if @pending[i][0] <= now_ms + STAGE_DEFER_EVENT_MS
        i += 1
      end
      false
    end

    # Stage one chunk of a discrete track, honoring a pending swap at
    # its cycle boundary.
    def stage_chunk(track)
      started_ms = Machine.board_millis
      from = track[:staged_until]
      swap_at = track[:swap_at]
      if swap_at && from >= swap_at
        track[:pattern] = track[:next_pattern]
        track[:next_pattern] = nil
        track[:swap_at] = nil
        swap_at = nil
      end
      to = from + STAGE_CHUNK
      to = swap_at if swap_at && swap_at < to
      haps = track[:pattern].query(TimeSpan.new(from, to))
      sink = track[:sink]
      name = track[:name]
      latency_ms = track[:latency_ms]
      i = 0
      while i < haps.length
        hap = haps[i]
        i += 1
        next unless hap.has_onset?
        at_ms = @clock.position_to_ms(hap.whole.begin_time).to_i - latency_ms
        @pending << [at_ms, sink, hap.value, name]
      end
      track[:staged_until] = to
      track[:last_good] = track[:pattern]
      elapsed = Machine.board_millis - started_ms
      @stage_ms_max = elapsed if elapsed > @stage_ms_max
    end

    # Remove staged events of a track at or after from_ms.
    def drop_pending(name, from_ms)
      i = 0
      while i < @pending.length
        event = @pending[i]
        if event[3] == name && event[0] >= from_ms
          @pending.delete_at(i)
        else
          i += 1
        end
      end
    end

    def track_failed(track, error)
      @errors[track[:name]] = "#{error.message} (#{error.class})"
      # Fall back to the last good pattern; if this was the last good
      # pattern itself, silence just this track.
      if track[:pattern].equal?(track[:last_good])
        track[:pattern] = Pattern.silence
      else
        track[:pattern] = track[:last_good]
      end
    end

  end
end
