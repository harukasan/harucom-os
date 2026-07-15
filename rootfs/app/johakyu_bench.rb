# johakyu_bench: on-board measurement of the staging query cost,
# isolated from the show loop: no audio engine, no DMX engine, no
# session. The background keyboard task still runs, as it does for
# every app, so interference from it shows up here too.
#
# Run from IRB:  run app/johakyu_bench.rb
#
# Prints four groups:
#   vm:       empty while-loop speed, the normalizer for everything
#   rational: Fraction arithmetic cost (the staging inner loop)
#   chunk:    per-statement query cost of one staging chunk; compare
#             with scripts/bench_johakyu.rb on the host and with the
#             M8 board baseline
#   gc:       full GC.start cost on the current heap

require "johakyu/control"
require "johakyu/scheduler"

def bench_ms
  started = Machine.board_millis
  yield
  Machine.board_millis - started
end

def johakyu_bench
  personality = Johakyu.personality("shehds_80w_led_spot_light", "13ch")
  patch = Johakyu::Patch.new
  patch.add(:s1, personality, base: 1)
  patch.add(:s2, personality, base: 14)
  patch.group(:all, :s1, :s2)
  Johakyu.patch = patch

  vm_ms = bench_ms do
    i = 0
    while i < 200_000
      i += 1
    end
  end
  puts "vm: 200k empty loop #{vm_ms} ms"

  # Floats are immediates under MRB_NO_BOXING: no allocation, so this
  # isolates value traffic and dispatch cost from the GC.
  x = 0.3
  y = 0.25
  float_ms = bench_ms do
    i = 0
    while i < 20_000
      c = x + y
      d = x * y
      c < d
      i += 1
    end
  end
  puts "float: 20k add+mul+cmp #{float_ms} ms"

  a = Johakyu::Fraction.new(1, 3)
  b = Johakyu::Fraction.new(1, 4)
  rational_ms = bench_ms do
    i = 0
    while i < 20_000
      c = a + b
      d = a * b
      c < d
      i += 1
    end
  end
  puts "rational: 20k add+mul+cmp #{rational_ms} ms"

  # The same loop with the collector off splits the op cost from the
  # GC time its allocations trigger: fast here means GC pacing is the
  # problem, slow here means the ops themselves are.
  GC.start
  GC.disable
  rational_nogc_ms = bench_ms do
    i = 0
    while i < 20_000
      c = a + b
      d = a * b
      c < d
      i += 1
    end
  end
  GC.enable
  GC.start
  puts "rational (GC off): 20k add+mul+cmp #{rational_nogc_ms} ms"

  cmp_ms = bench_ms do
    i = 0
    while i < 20_000
      a < b
      a <= b
      a == b
      i += 1
    end
  end
  puts "rational cmp: 20k lt+le+eq #{cmp_ms} ms"

  statements = {
    drums: Johakyu.sound("bd*4, hh*8"),
    pan1: Johakyu.pan(Johakyu.sine.slow(8)).on(:s1),
    tilt1: Johakyu.tilt(Johakyu.cosine.slow(8)).on(:s1),
    pan2: Johakyu.pan(Johakyu.sine.slow(8)).on(:s2),
    tilt2: Johakyu.tilt(Johakyu.cosine.slow(8)).on(:s2),
    colors: Johakyu.dimmer("1 0 1 0").color("<red blue>").on(:all),
  }
  chunk = Johakyu::Scheduler::STAGE_CHUNK
  puts "chunk query cost (#{chunk.num}/#{chunk.den} cycle, 40 rounds):"
  statements.each do |name, pattern|
    elapsed = bench_ms do
      i = 0
      while i < 40
        span = Johakyu::TimeSpan.new(chunk * i, chunk * (i + 1))
        pattern.query(span)
        i += 1
      end
    end
    puts "  #{name}: #{elapsed * 1000 / 40} us/chunk"
  end

  # A/B: the same loops through the original mruby-rational path
  # (Float-converting <=> in Ruby, < and <= from Comparable) to price
  # the cross-multiplication override on this exact build.
  ::Rational.class_eval do
    alias_method :bench_saved_spaceship, :<=>
    def <=>(other)
      return nil unless other.kind_of?(Numeric)
      self.to_f <=> other.to_f
    rescue
      nil
    end
    remove_method :<, :<=, :>, :>=
  end
  cmp_original_ms = bench_ms do
    i = 0
    while i < 20_000
      a < b
      a <= b
      a == b
      i += 1
    end
  end
  puts "rational cmp (original): 20k lt+le+eq #{cmp_original_ms} ms"
  rational_original_ms = bench_ms do
    i = 0
    while i < 20_000
      c = a + b
      d = a * b
      c < d
      i += 1
    end
  end
  puts "rational (original): 20k add+mul+cmp #{rational_original_ms} ms"
  [:drums, :colors].each do |name|
    pattern = statements[name]
    elapsed = bench_ms do
      i = 0
      while i < 40
        span = Johakyu::TimeSpan.new(chunk * i, chunk * (i + 1))
        pattern.query(span)
        i += 1
      end
    end
    puts "  #{name} (original cmp): #{elapsed * 1000 / 40} us/chunk"
  end
  ::Rational.class_eval do
    alias_method :<=>, :bench_saved_spaceship
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

  # Segment density: the control layer defaults signals to 8 segments
  # per cycle. Price a 16-segment signal to judge whether the halved
  # default was load bearing.
  [8, 16].each do |segments|
    pattern = Johakyu.pan(Johakyu.sine.slow(8).segment(segments)).on(:s1)
    elapsed = bench_ms do
      i = 0
      while i < 40
        span = Johakyu::TimeSpan.new(chunk * i, chunk * (i + 1))
        pattern.query(span)
        i += 1
      end
    end
    puts "segment #{segments}: #{elapsed * 1000 / 40} us/chunk"
  end

  round = 0
  while round < 3
    gc_ms = bench_ms { GC.start }
    round += 1
    puts "gc: start #{round} took #{gc_ms} ms"
  end

  # Memory layout sensitivity: the same rational loop with the heap
  # shifted 16 KB per round. Large swings between rounds mean the
  # known placement problem is back: VM data landing on addresses
  # that thrash the XIP cache against the hot code in flash. Pads are
  # kept alive so each round allocates from a shifted region.
  pads = []
  round = 0
  while round < 6
    GC.start
    layout_ms = bench_ms do
      i = 0
      while i < 5_000
        c = a + b
        d = a * b
        c < d
        i += 1
      end
    end
    puts "layout: pad #{pads.length * 16}KB rational5k #{layout_ms} ms"
    pads << ("x" * 16_384)
    round += 1
  end
  pads.clear
end

johakyu_bench
