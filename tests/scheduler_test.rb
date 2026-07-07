require "picotest"
require "johakyu/dsl"

# Clock, Scheduler, and Session behavior with stubbed time (R16: sound
# and light fire at identical target times from one clock).
class SchedulerTest < Picotest::Test
  def setup
    Machine.millis = 0
    DMX.reset
    Johakyu.patch = Johakyu.default_patch
  end

  def run_until(session_or_scheduler, until_ms, step_ms = 10)
    t = Machine.board_millis
    while t <= until_ms
      Machine.millis = t
      if session_or_scheduler.is_a?(Johakyu::Session)
        session_or_scheduler.update
      else
        session_or_scheduler.tick
        session_or_scheduler.pump
      end
      t += step_ms
    end
  end

  def steps(array)
    Johakyu::Session.steps_to_pattern(array, true)
  end

  def test_sound_and_light_share_target_times
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4)  # 2000 ms/cycle
    scheduler = Johakyu::Scheduler.new(clock)
    sound_hits = []
    light_hits = []
    scheduler.bind(:bd, steps([1, 0, 0, 0, 1, 0, 0, 0])) { |v, at| sound_hits << at }
    scheduler.bind(:light, steps([1, 0, 0, 0, 1, 0, 0, 0])) { |v, at| light_hits << at }
    run_until(scheduler, 4000)
    assert_equal [0, 1000, 2000, 3000, 4000], sound_hits
    assert_equal sound_hits, light_hits
  end

  def test_quantized_swap_at_cycle_boundary
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4)
    scheduler = Johakyu::Scheduler.new(clock)
    hits = []
    scheduler.bind(:x, steps([1, 0, 0, 0])) { |v, at| hits << at }
    run_until(scheduler, 2500)
    scheduler.bind(:x, steps([0, 1, 0, 0])) { |v, at| hits << at }
    run_until(scheduler, 6500)
    assert_equal [0, 2000, 4500, 6500], hits
  end

  def test_swap_drops_events_staged_past_boundary
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4)
    scheduler = Johakyu::Scheduler.new(clock)
    hits = []
    scheduler.bind(:x, steps([1, 0, 0, 0])) { |v, at| hits << at }
    run_until(scheduler, 3600)
    scheduler.bind(:x, steps([0, 1, 0, 0])) { |v, at| hits << at }
    run_until(scheduler, 6600)
    assert_equal [0, 2000, 4500, 6500], hits
  end

  def test_continuous_sampling
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4)
    scheduler = Johakyu::Scheduler.new(clock)
    samples = []
    scheduler.bind_continuous(:pan, Johakyu.sine) { |v, _at| samples << v }
    run_until(scheduler, 2000, 20)
    # Sampling is capped at CONTINUOUS_INTERVAL_MS (25 ms), so 20 ms
    # ticks sample every other tick.
    assert_equal true, samples.length >= 45
    assert_equal true, samples.all? { |v| v >= 0.0 && v <= 1.0 }
  end

  def test_error_fallback_isolates_track
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4)
    scheduler = Johakyu::Scheduler.new(clock)
    good = 0
    scheduler.bind(:good, Johakyu::Pattern.pure(1)) { |v, at| good += 1 }
    scheduler.bind(:bad, Johakyu::Pattern.new { |span| raise "boom" }) { |v, at| }
    run_until(scheduler, 4000)
    assert_equal true, scheduler.last_error(:bad) != nil
    assert_equal 3, good
  end

  def test_session_kick_and_dimmer_land_together
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.seq(:bd, [1, 0, 0, 0, 1, 0, 0, 0])
    session.dmx_seq(:s1, :dimmer, [1.0, 0, 0, 0, 1.0, 0, 0, 0])
    run_until(session, 4000)
    tone_times = audio.tones.map { |e| e[1] }
    dimmer_on = DMX.writes.select { |w| w[1] == 6 && w[2] == 255 }.map { |w| w[0] }
    assert_equal [0, 1000, 2000, 3000, 4000], tone_times
    assert_equal tone_times, dimmer_on
  end

  def test_gate_runs_from_actual_start_when_late
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.seq(:bd, [1, 0, 0, 0])
    run_until(session, 1990)
    audio.events.clear
    Machine.millis = 2150
    session.update
    run_until(session, 2400)
    assert_equal 2150, audio.tones[0][1]
    assert_equal true, audio.stops[0][1] >= 2240
  end

  def test_new_note_drops_stale_gate
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.seq(:bd, [1, 1, 0, 0])
    session.update
    Machine.millis = 600
    session.update
    early_stops = audio.stops.select { |e| e[1] <= 600 }
    assert_equal 0, early_stops.length
    run_until(session, 800)
    assert_equal true, audio.stops[0][1] >= 690
  end

  def test_audio_latency_fires_sound_early
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 35)
    session.seq(:bd, [1, 0, 0, 0])
    session.dmx_seq(:s1, :dimmer, [1.0, 0, 0, 0])
    run_until(session, 4100, 5)
    assert_equal 1965, audio.tones[1][1]
    dimmer_on = DMX.writes.select { |w| w[1] == 6 && w[2] == 255 }.map { |w| w[0] }
    assert_equal 2000, dimmer_on[1]
  end

  def test_tempo_change_is_continuous
    Machine.millis = 10_000
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4)
    Machine.millis = 12_000
    before = clock.position
    clock.bpm = 240
    assert_equal true, (before - clock.position).abs < 1e-9
    Machine.millis = 13_000
    assert_equal true, (clock.position - 2.0).abs < 1e-9
  end

  def test_sound_mini_notation
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.sound("bd ~ sn ~")
    run_until(session, 1990)
    assert_equal [:tone, 0, 0, 110, 15], audio.tones[0]
    assert_equal [:tone, 1000, 1, 240, 15], audio.tones[1]
  end

  def test_dmx_mini_notation
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.dmx(:s1).color("red blue").dimmer("1 0 0.5 0")
    run_until(session, 1990)
    colors = DMX.writes.select { |w| w[1] == 8 }.map { |w| [w[0], w[2]] }
    assert_equal [[0, 12], [1000, 28]], colors
    dimmers = DMX.writes.select { |w| w[1] == 6 }.map { |w| [w[0], w[2]] }
    assert_equal [[0, 255], [500, 0], [1000, 128], [1500, 0]], dimmers
  end

  def test_signal_autobinds_continuous
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.dmx(:s2).pan(Johakyu.sine.range(0.2, 0.8).slow(8))
    run_until(session, 500, 20)
    pans = DMX.writes.select { |w| w[1] == 14 }
    # A discrete bind would write at most once here; sampling writes
    # every CONTINUOUS_INTERVAL_MS.
    assert_equal true, pans.length >= 10
    assert_equal true, pans.all? { |w| w[2] >= 51 && w[2] <= 204 }
  end

  def test_sound_chain_every_fast
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.sound("bd*2").every(2) { |p| p.fast(2) }
    run_until(session, 3990)
    times = audio.tones.map { |e| e[1] }
    assert_equal [0, 1000, 2000, 2500, 3000, 3500], times
  end

  def test_sound_chain_applies_from_first_cycle
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.sound("bd sn").rev
    run_until(session, 1990)
    # rev must already hold at the first bind: snare first, kick second
    assert_equal 1, audio.tones[0][2]
    assert_equal 0, audio.tones[1][2]
  end

  def test_euclid_structures_dmx
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.dmx(:s1).dimmer(Johakyu.euclid(3, 8))
    run_until(session, 1990)
    ons = DMX.writes.select { |w| w[1] == 6 }.map { |w| [w[0], w[2]] }
    assert_equal [[0, 255], [750, 255], [1500, 255]], ons
  end

  def test_signal_swaps_to_discrete_at_boundary
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: 0)
    session.dmx(:s2).pan(Johakyu.sine.slow(8))
    run_until(session, 900)
    session.dmx(:s2).pan("0.25 0.75")
    run_until(session, 3990)
    silent = DMX.writes.select { |w| w[1] == 14 && w[0] > 900 && w[0] < 2000 }
    assert_equal 0, silent.length
    steps = DMX.writes.select { |w| w[1] == 14 && w[0] >= 2000 }.map { |w| [w[0], w[2]] }
    assert_equal [[2000, 64], [3000, 191]], steps
  end
end
