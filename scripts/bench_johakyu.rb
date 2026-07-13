# Host bench for the all-pattern scheduler (B4 gate). Runs on the
# host test VM:
#
#   lib/picoruby/build/harucom-host-test/bin/picoruby scripts/bench_johakyu.rb
#
# Measures the representative show from research 08: pan+tilt
# segment(32) on two fixtures, kick4+hats8, and a color beat. Reports
# per-statement query cost for one staging chunk (1/4 cycle) and the
# scheduler tick statistics over a simulated run. Compare against the
# M8 baseline before applying the optimization ladder.

$LOAD_PATH = ["rootfs/lib"]

# Minimal stand-ins (no stubbed clock: timings are real).
module DMX
  def self.set(channel, value); end
  def self.set_range(channel, values); end
  def self.keepalive; end
end

class BenchAudio
  def sample_clock
    Machine.board_millis * 50
  end

  def play_at(sample, channel, volume = 15)
    true
  end

  def stop_all; end
end

require "johakyu/live"

personality = Johakyu.personality(
  "rootfs/data/dmx/fixtures/shehds_80w_led_spot_light.json", "13ch")
patch = Johakyu::Patch.new
patch.add(:s1, personality, base: 1)
patch.add(:s2, personality, base: 14)
patch.group(:all, :s1, :s2)
Johakyu.patch = patch

STATEMENTS = {
  drums: Johakyu.sound("bd*4, hh*8"),
  pan1: Johakyu.pan(Johakyu.sine.slow(8)).on(:s1),
  tilt1: Johakyu.tilt(Johakyu.cosine.slow(8)).on(:s1),
  pan2: Johakyu.pan(Johakyu.sine.slow(8)).on(:s2),
  tilt2: Johakyu.tilt(Johakyu.cosine.slow(8)).on(:s2),
  colors: Johakyu.dimmer("1 0 1 0").color("<red blue>").on(:all),
}

# Per-statement staging chunk cost: query one scheduler chunk.
chunk = Johakyu::Scheduler::STAGE_CHUNK
puts "chunk query cost (#{chunk.num}/#{chunk.den} cycle, 40 rounds):"
STATEMENTS.each do |name, pattern|
  rounds = 40
  started = Machine.board_millis
  i = 0
  while i < rounds
    span = Johakyu::TimeSpan.new(chunk * i, chunk * (i + 1))
    pattern.query(span)
    i += 1
  end
  elapsed = Machine.board_millis - started
  puts format("  %-7s %6.2f ms/chunk", name.to_s, elapsed.to_f / rounds)
end

# Full session run in real time: bind everything and update in a busy
# loop for a few seconds, then read the R15 counters.
session = Johakyu::Session.new(audio: BenchAudio.new, bpm: 120)
STATEMENTS.each do |name, pattern|
  session.bind_statement(name, pattern)
end

run_ms = 5000
started = Machine.board_millis
updates = 0
while Machine.board_millis - started < run_ms
  session.update
  updates += 1
end

scheduler = session.scheduler
puts format("session run: %d ms, %d updates", run_ms, updates)
puts format("  tick avg %.2f ms, tick max %d ms", scheduler.tick_ms_average,
            scheduler.tick_ms_max)
puts format("  stage max %d ms, fired %d, late max %d ms", scheduler.stage_ms_max,
            scheduler.fired_count, scheduler.fire_delay_ms_max)
