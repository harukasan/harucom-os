# Johakyu pattern core, compatible with the basics of asonas/strudel-rb.
#
# A Pattern maps a query time span to an array of Haps (events). Time is
# exact rational arithmetic on mruby-rational (C-backed; the pure Ruby
# Fraction class this replaced dominated the board tick cost through
# per-operation allocation and GC). Exactness matters because onset
# detection compares whole.begin_time == part.begin_time; floating point
# would lose onsets at cycle boundaries.
#
# Deviations from strudel-rb kept small on purpose:
# - query takes a TimeSpan directly (no State object, controls unused)
# - only the core factories and transforms needed by the Johakyu DSL
#   stages are ported (pure/fastcat/slowcat/stack/euclid, fast/slow/rev/
#   every/struct/mask/segment/range/degrade_by, add/sub/mul/div)
# - hot query paths use while loops (mruby lacks flat_map/filter_map)

module Johakyu
  # Cycle helpers on Rational itself, so pattern code calls them with
  # no wrapper object. num/den keep the old Fraction reader names.
  class ::Rational
    def num
      numerator
    end

    def den
      denominator
    end

    # Integer floor (cycle number). Integer#div floors.
    def floor_i
      numerator.div(denominator)
    end

    # Cycle start time.
    def sam
      Rational(floor_i, 1)
    end

    def next_sam
      Rational(floor_i + 1, 1)
    end

    # Position within the cycle.
    def cycle_pos
      self - sam
    end

    def whole_cycle
      Johakyu::TimeSpan.new(sam, next_sam)
    end

    def to_cycle_i
      floor_i
    end

    # The bundled mruby-rational defines <=> in Ruby through Float
    # conversion with a rescue frame per call, and <, <=, >, >= go
    # through Comparable on top: several dispatches per comparison on
    # the hottest path of the query engine (span intersection
    # compares constantly). Cross-multiplied integer comparison is
    # exact (denominators are positive after normalization),
    # allocation free, and one dispatch deep. Exactness also improves:
    # Float conversion cannot distinguish rationals closer than one
    # double ulp.
    def <=>(other)
      if other.is_a?(Rational)
        numerator * other.denominator <=> other.numerator * denominator
      elsif other.is_a?(Integer)
        numerator <=> other * denominator
      elsif other.is_a?(Float)
        to_f <=> other
      else
        nil
      end
    end

    def <(other)
      cmp = self <=> other
      raise ArgumentError, "comparison of Rational with #{other.class} failed" if cmp.nil?
      cmp < 0
    end

    def <=(other)
      cmp = self <=> other
      raise ArgumentError, "comparison of Rational with #{other.class} failed" if cmp.nil?
      cmp <= 0
    end

    def >(other)
      cmp = self <=> other
      raise ArgumentError, "comparison of Rational with #{other.class} failed" if cmp.nil?
      cmp > 0
    end

    def >=(other)
      cmp = self <=> other
      raise ArgumentError, "comparison of Rational with #{other.class} failed" if cmp.nil?
      cmp >= 0
    end
  end

  # Exact rational time. The arithmetic runs in C (mruby-rational);
  # this layer adds the cycle helpers the pattern core needs and keeps
  # the Fraction factory API. Exactness matters because onset
  # comparisons decide whether an event fires once or twice at chunk
  # boundaries.
  module Fraction
    # Floats quantize onto this grid (covers halves/thirds/quarters/
    # fifths/16ths), so clock positions land on exact grid points.
    FLOAT_DENOMINATOR = 3840

    def self.of(value)
      return value if value.is_a?(Rational)
      if value.is_a?(Float)
        Rational((value * FLOAT_DENOMINATOR).round, FLOAT_DENOMINATOR)
      else
        Rational(value, 1)
      end
    end

    def self.new(num, den = 1)
      Rational(num, den)
    end
  end

  class TimeSpan
    attr_reader :begin_time, :end_time

    def initialize(begin_time, end_time)
      @begin_time = begin_time
      @end_time = end_time
    end

    def duration
      @end_time - @begin_time
    end

    def midpoint
      @begin_time + duration / Fraction.new(2)
    end

    # Split at cycle boundaries.
    def span_cycles
      result = []
      return result if @end_time <= @begin_time
      current = @begin_time
      while current < @end_time
        cycle_end = current.next_sam
        segment_end = cycle_end < @end_time ? cycle_end : @end_time
        result << TimeSpan.new(current, segment_end)
        current = segment_end
      end
      result
    end

    def intersection(other)
      b = @begin_time > other.begin_time ? @begin_time : other.begin_time
      e = @end_time < other.end_time ? @end_time : other.end_time
      return nil if b >= e
      TimeSpan.new(b, e)
    end

    def with_time(&block)
      TimeSpan.new(block.call(@begin_time), block.call(@end_time))
    end

    def ==(other)
      return false unless other.is_a?(TimeSpan)
      @begin_time == other.begin_time && @end_time == other.end_time
    end

    def inspect
      "TimeSpan(#{@begin_time.inspect}, #{@end_time.inspect})"
    end
  end

  # One event: value active over part, belonging to a whole timespan.
  # whole is nil for continuous signals (no onset).
  class Hap
    attr_reader :whole, :part, :value

    def initialize(whole, part, value)
      @whole = whole
      @part = part
      @value = value
    end

    def has_onset?
      return false if @whole.nil?
      @whole.begin_time == @part.begin_time
    end

    def with_value(&block)
      Hap.new(@whole, @part, block.call(@value))
    end

    def with_span(&block)
      Hap.new(@whole ? block.call(@whole) : nil, block.call(@part), @value)
    end

    def inspect
      "Hap(whole: #{@whole.inspect}, part: #{@part.inspect}, value: #{@value.inspect})"
    end
  end

  class Pattern
    def initialize(&query)
      @query = query
    end

    # span -> array of Haps
    def query(span)
      @query.call(span)
    end

    def query_arc(begin_time, end_time)
      query(TimeSpan.new(Fraction.of(begin_time), Fraction.of(end_time)))
    end

    # True when this pattern is a continuous signal: its Haps carry no
    # whole, so nothing ever has an onset. Probed with one tiny query.
    # The DSL uses this to choose between staged events and per-tick
    # sampling in the scheduler.
    def continuous?
      probe = TimeSpan.new(Fraction.new(0),
                           Fraction.new(1, Fraction::FLOAT_DENOMINATOR))
      haps = query(probe)
      haps.length > 0 && haps[0].whole.nil?
    end

    # Sample the value active at a cycle position (Float). Returns nil
    # when nothing is active. Signal overrides this with a Float-only
    # fast path; this generic version queries a tiny span, which costs
    # Fraction and Hap allocations, so the scheduler prefers Signals
    # for per-tick sampling.
    def sample(position)
      t = Fraction.of(position)
      haps = query(TimeSpan.new(t, t + Fraction.new(1, Fraction::FLOAT_DENOMINATOR)))
      haps.length > 0 ? haps[0].value : nil
    end

    # ---- factories ----

    def self.pure(value)
      Pattern.new do |span|
        spans = span.span_cycles
        haps = []
        i = 0
        while i < spans.length
          sub = spans[i]
          haps << Hap.new(sub.begin_time.whole_cycle, sub, value)
          i += 1
        end
        haps
      end
    end

    def self.silence
      Pattern.new { |_span| [] }
    end

    # Strings become mini notation once the parser exists (M7); until
    # then they are plain values.
    def self.reify(value)
      return value if value.is_a?(Pattern)
      pure(value)
    end

    # One item per cycle.
    def self.slowcat(*items)
      return silence if items.empty?
      patterns = []
      i = 0
      while i < items.length
        patterns << reify(items[i])
        i += 1
      end
      n = patterns.length
      Pattern.new do |span|
        spans = span.span_cycles
        haps = []
        i = 0
        while i < spans.length
          sub = spans[i]
          index = sub.begin_time.floor_i % n
          haps.concat(patterns[index].query(sub))
          i += 1
        end
        haps
      end
    end

    # All items within one cycle.
    def self.fastcat(*items)
      return silence if items.empty?
      slowcat(*items).fast(items.length)
    end

    def self.sequence(*items)
      fastcat(*items)
    end

    def self.stack(*items)
      return silence if items.empty?
      patterns = []
      i = 0
      while i < items.length
        patterns << reify(items[i])
        i += 1
      end
      Pattern.new do |span|
        haps = []
        i = 0
        while i < patterns.length
          haps.concat(patterns[i].query(span))
          i += 1
        end
        haps
      end
    end

    # Euclidean rhythm: pulses spread over steps, value true.
    def self.euclid(pulses, steps, rotation = 0)
      return silence if pulses <= 0 || steps <= 0
      flags = bjorklund(pulses, steps)
      if rotation != 0
        r = rotation % steps
        flags = flags[r, steps - r] + flags[0, r] if r != 0
      end
      beats = []
      i = 0
      while i < steps
        beats << i if flags[i]
        i += 1
      end
      Pattern.new do |span|
        spans = span.span_cycles
        haps = []
        i = 0
        while i < spans.length
          sub = spans[i]
          cycle = sub.begin_time.sam
          j = 0
          while j < beats.length
            pos = beats[j]
            whole = TimeSpan.new(cycle + Fraction.new(pos, steps),
                                 cycle + Fraction.new(pos + 1, steps))
            part = whole.intersection(sub)
            haps << Hap.new(whole, part, true) if part
            j += 1
          end
          i += 1
        end
        haps
      end
    end

    def self.bjorklund(pulses, steps)
      return Array.new(steps, false) if pulses == 0
      return Array.new(steps, true) if pulses >= steps
      groups = []
      i = 0
      while i < pulses
        groups << [true]
        i += 1
      end
      i = 0
      while i < steps - pulses
        groups << [false]
        i += 1
      end
      loop do
        last_group = groups[groups.length - 1]
        remainder_count = 0
        i = 0
        while i < groups.length
          remainder_count += 1 if groups[i] == last_group
          i += 1
        end
        break if remainder_count <= 1 || remainder_count == groups.length
        i = 0
        while i < remainder_count
          break if groups.length <= remainder_count
          tail = groups.pop
          groups[i] = groups[i] + tail
          i += 1
        end
      end
      flat = []
      i = 0
      while i < groups.length
        flat.concat(groups[i])
        i += 1
      end
      flat
    end

    # ---- time transforms ----

    def with_query_time(&block)
      source = self
      Pattern.new do |span|
        source.query(span.with_time(&block))
      end
    end

    def with_hap_time(&block)
      source = self
      Pattern.new do |span|
        haps = source.query(span)
        result = []
        i = 0
        while i < haps.length
          result << haps[i].with_span { |s| s.with_time(&block) }
          i += 1
        end
        result
      end
    end

    def fast(factor)
      factor = Fraction.of(factor)
      raise ArgumentError, "fast factor must be positive" if factor.num <= 0
      with_query_time { |t| t * factor }.with_hap_time { |t| t / factor }
    end

    def slow(factor)
      fast(Fraction.new(1) / Fraction.of(factor))
    end

    # Shift the pattern later in time by amount cycles (early shifts
    # it back). The basis of spread: copies of one pattern offset per
    # fixture member.
    def late(amount)
      amount = Fraction.of(amount)
      with_query_time { |t| t - amount }.with_hap_time { |t| t + amount }
    end

    def early(amount)
      late(Fraction.new(0) - Fraction.of(amount))
    end

    def split_queries
      source = self
      Pattern.new do |span|
        spans = span.span_cycles
        haps = []
        i = 0
        while i < spans.length
          haps.concat(source.query(spans[i]))
          i += 1
        end
        haps
      end
    end

    # Apply the block-transformed pattern on the last of every n cycles.
    def every(n, &func)
      source = self
      transformed = func.call(self)
      Pattern.new do |span|
        spans = span.span_cycles
        haps = []
        i = 0
        while i < spans.length
          sub = spans[i]
          pat = (sub.begin_time.floor_i % n == n - 1) ? transformed : source
          haps.concat(pat.query(sub))
          i += 1
        end
        haps
      end
    end

    # Reverse playback within each cycle.
    def rev
      source = split_queries
      Pattern.new do |span|
        spans = span.span_cycles
        haps = []
        k = 0
        while k < spans.length
          sub = spans[k]
          cycle = sub.begin_time.sam
          reflected = TimeSpan.new(reflect_time(sub.end_time, cycle),
                                   reflect_time(sub.begin_time, cycle))
          inner = source.query(reflected)
          i = 0
          while i < inner.length
            hap = inner[i]
            hap_cycle = hap.whole ? hap.whole.begin_time.sam : hap.part.begin_time.sam
            new_whole = nil
            if hap.whole
              new_whole = TimeSpan.new(reflect_time(hap.whole.end_time, hap_cycle),
                                       reflect_time(hap.whole.begin_time, hap_cycle))
            end
            new_part = TimeSpan.new(reflect_time(hap.part.end_time, hap_cycle),
                                    reflect_time(hap.part.begin_time, hap_cycle))
            haps << Hap.new(new_whole, new_part, hap.value)
            i += 1
          end
          k += 1
        end
        haps.sort { |a, b| a.part.begin_time <=> b.part.begin_time }
      end
    end

    # ---- value transforms ----

    def with_value(&block)
      source = self
      Pattern.new do |span|
        haps = source.query(span)
        result = []
        i = 0
        while i < haps.length
          result << haps[i].with_value(&block)
          i += 1
        end
        result
      end
    end

    def fmap(&block)
      with_value(&block)
    end

    # Attach a control to every event: sample `other` at each event's
    # onset and merge it into the control map under `key` (structure
    # from left, like Tidal's # operator). Values must already be
    # control maps (Hash); the control layer wraps raw values before
    # calling this. A Pattern samples through Pattern#sample (Signals
    # take their Float fast path); anything else is a constant. When
    # the sampled value is nil (silence in `other`), the event passes
    # through unchanged.
    def with_control(key, other)
      unless other.is_a?(Pattern)
        return with_value do |value|
          merged = value.dup
          merged[key] = other
          merged
        end
      end
      source = self
      Pattern.new do |span|
        haps = source.query(span)
        result = []
        i = 0
        while i < haps.length
          hap = haps[i]
          # Exact rational onset: a Float round trip quantizes onto the
          # 1/3840 grid and picks the neighbor cell for onsets whose
          # denominator does not divide it (euclid(5,7) and friends).
          at = hap.whole ? hap.whole.begin_time : hap.part.begin_time
          sampled = other.sample(at)
          if sampled.nil?
            result << hap
          else
            result << hap.with_value do |value|
              merged = value.dup
              merged[key] = sampled
              merged
            end
          end
          i += 1
        end
        result
      end
    end

    def onsets_only
      source = self
      Pattern.new do |span|
        haps = source.query(span)
        result = []
        i = 0
        while i < haps.length
          result << haps[i] if haps[i].has_onset?
          i += 1
        end
        result
      end
    end

    # Scale 0.0-1.0 values to min..max.
    def range(min, max)
      with_value { |v| min + v * (max - min) }
    end

    # ---- structure transforms ----

    # Keep this pattern's values, take rhythm from a boolean pattern.
    def struct(bool_pattern)
      bool_pattern = Pattern.reify(bool_pattern)
      source = self
      Pattern.new do |span|
        bool_haps = bool_pattern.query(span)
        haps = []
        i = 0
        while i < bool_haps.length
          bool_hap = bool_haps[i]
          i += 1
          next unless Pattern.active_value?(bool_hap.value)
          inner = source.query(bool_hap.whole || bool_hap.part)
          j = 0
          while j < inner.length
            hap = inner[j]
            j += 1
            part = hap.part.intersection(bool_hap.part)
            next unless part
            haps << Hap.new(bool_hap.whole, part, hap.value)
          end
        end
        haps
      end
    end

    # Keep events where the boolean pattern is truthy (and not 0),
    # preserving this pattern's timing.
    def mask(bool_pattern)
      bool_pattern = Pattern.reify(bool_pattern)
      source = self
      Pattern.new do |span|
        haps = source.query(span)
        result = []
        i = 0
        while i < haps.length
          hap = haps[i]
          i += 1
          bool_haps = bool_pattern.query(hap.whole || hap.part)
          keep = false
          j = 0
          while j < bool_haps.length
            bh = bool_haps[j]
            j += 1
            if Pattern.active_value?(bh.value) && bh.part.intersection(hap.part)
              keep = true
              break
            end
          end
          result << hap if keep
        end
        result
      end
    end

    # Euclidean structure applied to this pattern's values.
    def euclid(pulses, steps, rotation = 0)
      struct(Pattern.euclid(pulses, steps, rotation))
    end

    # Sample a continuous pattern into n discrete events per cycle.
    def segment(n)
      source = self
      Pattern.new do |span|
        spans = span.span_cycles
        haps = []
        i = 0
        while i < spans.length
          sub = spans[i]
          cycle = sub.begin_time.sam
          j = 0
          while j < n
            whole = TimeSpan.new(cycle + Fraction.new(j, n),
                                 cycle + Fraction.new(j + 1, n))
            part = whole.intersection(sub)
            if part
              inner = source.query(whole)
              haps << Hap.new(whole, part, inner[0].value) if inner.length > 0
            end
            j += 1
          end
          i += 1
        end
        haps
      end
    end

    # Remove events with the given probability (deterministic per time).
    def degrade_by(amount)
      source = self
      Pattern.new do |span|
        haps = source.query(span)
        result = []
        i = 0
        while i < haps.length
          hap = haps[i]
          i += 1
          t = (hap.whole || hap.part).begin_time.to_f
          result << hap if Pattern.time_to_rand(t + 0.456) >= amount
        end
        result
      end
    end

    def degrade
      degrade_by(0.5)
    end

    # ---- arithmetic ----

    def add(other)
      apply_op(other) { |a, b| a + b }
    end

    def sub(other)
      apply_op(other) { |a, b| a - b }
    end

    def mul(other)
      apply_op(other) { |a, b| a * b }
    end

    def div(other)
      apply_op(other) { |a, b| a / b }
    end

    # Truthiness for boolean patterns. Mini notation atoms stay
    # Strings, so "0" counts as false alongside 0, false, and nil.
    def self.active_value?(value)
      return false if value.nil? || value == false
      value != 0 && value != "0"
    end

    # Deterministic pseudo-random value for a given time (0..1),
    # matching strudel-rb's time_to_rand.
    def self.time_to_rand(x)
      t = x / 300.0
      frac = t - t.to_i
      seed = (frac * 536_870_912).to_i
      a = int32((seed << 13) ^ seed)
      b = int32((a >> 17) ^ a)
      c = int32((b << 5) ^ b)
      (c.abs % 536_870_912) / 536_870_912.0
    end

    def self.int32(n)
      n &= 0xFFFFFFFF
      n >= 0x80000000 ? n - 0x100000000 : n
    end

    def inspect
      "Pattern"
    end

    private

    def reflect_time(t, cycle)
      cycle + (Fraction.new(1) - (t - cycle))
    end

    def apply_op(other, &block)
      other_pattern = Pattern.reify(other)
      source = self
      Pattern.new do |span|
        left_haps = source.query(span)
        haps = []
        i = 0
        while i < left_haps.length
          left = left_haps[i]
          i += 1
          right_haps = other_pattern.query(left.whole || left.part)
          j = 0
          while j < right_haps.length
            right = right_haps[j]
            j += 1
            part = left.part.intersection(right.part)
            next unless part
            whole = nil
            whole = left.whole.intersection(right.whole) if left.whole && right.whole
            haps << Hap.new(whole, part, block.call(left.value, right.value))
          end
        end
        haps
      end
    end
  end

  # Module-level shorthand so DSL code reads like the Strudel examples:
  # dmx(:all).strobe(Johakyu.euclid(3, 8)).
  def self.euclid(pulses, steps, rotation = 0)
    Pattern.euclid(pulses, steps, rotation)
  end
end
