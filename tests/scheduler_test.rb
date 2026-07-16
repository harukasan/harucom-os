require "picotest"
require "johakyu/dsl"

# Clock, Scheduler, and Session behavior with stubbed time. Sound
# reservations and light writes come from one query per statement; the
# FakeAudio sample clock is anchored so a reservation for target_ms
# resolves to target_ms * 50 exactly.
class SchedulerTest < Picotest::Test
  def setup
    Machine.millis = 0
    DMX.reset
    Johakyu.patch = johakyu_test_patch
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

  # Steps array to pattern, for raw scheduler tests (the DSL itself
  # went all-pattern; the scheduler still just sees patterns).
  def steps(array)
    items = []
    i = 0
    while i < array.length
      value = array[i]
      if value.nil? || value == 0
        items << Johakyu::Pattern.silence
      else
        items << Johakyu::Pattern.pure(value)
      end
      i += 1
    end
    Johakyu::Pattern.fastcat(*items)
  end

  def new_session(latency = 0)
    audio = FakeAudio.new
    session = Johakyu::Session.new(audio: audio, bpm: 120, audio_latency_ms: latency)
    [session, audio]
  end

  def play_times(audio)
    audio.plays.map { |e| e[1] }
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

  def test_staging_yields_to_due_events
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4)
    scheduler = Johakyu::Scheduler.new(clock)
    scheduler.bind(:x, steps([1, 1, 1, 1, 1, 1, 1, 1])) { |v, at| }
    # the fresh bind stages the first quarter cycle: onsets at 0, 250
    assert_equal 2, scheduler.pending_count
    Machine.millis = 240
    scheduler.tick
    # an event is due within STAGE_DEFER_EVENT_MS and the track has
    # runway, so the tick must not stage ahead of firing it
    assert_equal 2, scheduler.pending_count
    scheduler.pump
    assert_equal 1, scheduler.pending_count
    Machine.millis = 260
    scheduler.pump
    Machine.millis = 300
    scheduler.tick
    # nothing due now, staging resumes
    assert_equal true, scheduler.pending_count >= 1
  end

  # ---- Session dispatcher (all-pattern) ----

  def test_kick_and_dimmer_land_together
    session, audio = new_session
    session.bind_statement(:drums,
                           Johakyu.sound("bd ~ ~ ~ bd ~ ~ ~").dimmer(1.0).on(:s1))
    run_until(session, 4000)
    kick_samples = play_times(audio)
    dimmer_on = DMX.writes.select { |w| w[1] == 6 && w[2] == 255 }.map { |w| w[0] }
    assert_equal [0, 1000, 2000, 3000, 4000], dimmer_on
    assert_equal dimmer_on.map { |ms| ms * 50 }, kick_samples
    assert_equal 0, session.output_late_count
  end

  def test_output_overrun_past_lead_is_counted
    session, _audio = new_session
    session.bind_statement(:drums, Johakyu.sound("bd*4"))
    assert_equal 0, session.output_late_count
    # a long stall: the first update happens 700 ms in, so events fire
    # past their targets by more than the lead can absorb
    Machine.millis = 700
    session.update
    assert_equal true, session.output_late_count >= 1
    assert_equal 700, session.output_late_ms_max
  end

  def test_sound_reserves_sample_accurate_despite_loop_jitter
    session, audio = new_session
    session.bind_statement(:drums, Johakyu.sound("bd*4"))
    # a coarse 17 ms loop cannot hit 500 ms multiples, reservations must
    run_until(session, 2000, 17)
    samples = play_times(audio)
    assert_equal [0, 25_000, 50_000, 75_000, 100_000], samples[0, 5]
  end

  def test_audio_latency_trims_sound_earlier
    session, audio = new_session(35)
    session.bind_statement(:drums, Johakyu.sound("bd ~ ~ ~").dimmer(1.0).on(:s1))
    run_until(session, 4100, 5)
    assert_equal (2000 - 35) * 50, play_times(audio)[1]
    dimmer_on = DMX.writes.select { |w| w[1] == 6 && w[2] == 255 }.map { |w| w[0] }
    assert_equal 2000, dimmer_on[1]
  end

  def test_sound_mini_notation_maps_kit_channels
    session, audio = new_session
    session.bind_statement(:drums, Johakyu.sound("bd ~ sn ~"))
    run_until(session, 1990)
    plays = audio.plays
    assert_equal [0, 3, 14], [plays[0][1], plays[0][2], plays[0][3]]
    assert_equal [50_000, 4, 14], [plays[1][1], plays[1][2], plays[1][3]]
  end

  def test_unknown_voice_is_ignored
    session, audio = new_session
    session.bind_statement(:drums, Johakyu.sound("bd zz"))
    run_until(session, 1990)
    # both cycle kicks (the 2000 one reserves early); zz never plays
    assert_equal 2, audio.plays.length
  end

  def test_dmx_mini_notation
    session, _audio = new_session
    session.bind_statement(:color, Johakyu.dmx_builder(:s1).color("red blue"))
    session.bind_statement(:dim, Johakyu.dmx_builder(:s1).dimmer("1 0 0.5 0"))
    run_until(session, 1990)
    colors = DMX.writes.select { |w| w[1] == 8 }.map { |w| [w[0], w[2]] }
    assert_equal [[0, 12], [1000, 28]], colors
    dimmers = DMX.writes.select { |w| w[1] == 6 }.map { |w| [w[0], w[2]] }
    assert_equal [[0, 255], [500, 0], [1000, 128], [1500, 0]], dimmers
  end

  def test_light_without_target_goes_to_all
    session, _audio = new_session
    session.bind_statement(:dim, Johakyu.dimmer("1"))
    run_until(session, 100)
    # both fixtures' dimmer channels (6 and 19) get the write
    channels = DMX.writes.map { |w| w[1] }
    assert_equal true, channels.include?(6)
    assert_equal true, channels.include?(19)
  end

  def test_segmented_signal_drives_pan
    session, _audio = new_session
    session.bind_statement(:pan,
                           Johakyu.dmx_builder(:s2).pan(Johakyu.sine.range(0.2, 0.8).slow(8)))
    run_until(session, 500, 20)
    pans = DMX.writes.select { |w| w[1] == 14 }
    # the default segment(16) yields a write every 125 ms
    assert_equal true, pans.length >= 2
    assert_equal true, pans.all? { |w| w[2] >= 51 && w[2] <= 204 }
  end

  def test_euclid_structures_dmx
    session, _audio = new_session
    session.bind_statement(:dim, Johakyu.dmx_builder(:s1).dimmer(Johakyu.euclid(3, 8)))
    run_until(session, 1990)
    ons = DMX.writes.select { |w| w[1] == 6 }.map { |w| [w[0], w[2]] }
    assert_equal [[0, 255], [750, 255], [1500, 255]], ons
  end

  def test_pattern_chain_before_bind
    session, audio = new_session
    session.bind_statement(:drums, Johakyu.sound("bd*2").every(2) { |p| p.fast(2) })
    run_until(session, 3990)
    times = play_times(audio).map { |s| s / 50 }
    # the 4000 event reserves early (RESERVE_LEAD_MS before its target)
    assert_equal [0, 1000, 2000, 2500, 3000, 3500, 4000], times
  end

  # A rebind inside the lead window must not restage events the old
  # binding already fired: the sound reservation cannot be recalled,
  # so restaging double-triggers the boundary beat (heard as a flam
  # on every quick re-eval near a cycle boundary).
  def test_rebind_inside_the_lead_window_does_not_double_fire
    session, audio = new_session
    session.bind_statement(:drums, Johakyu.sound("bd ~ ~ ~"))
    run_until(session, 1750)
    session.bind_statement(:drums, Johakyu.sound("bd ~ ~ ~"))
    run_until(session, 2600)
    times = play_times(audio)
    assert_equal times.uniq.length, times.length
    assert_equal [0, 100_000], times[0, 2]
  end

  def test_statement_swap_is_quantized
    session, audio = new_session
    session.bind_statement(:drums, Johakyu.sound("bd ~ ~ ~"))
    run_until(session, 2500)
    session.bind_statement(:drums, Johakyu.sound("~ bd ~ ~"))
    run_until(session, 6500)
    times = play_times(audio).map { |s| s / 50 }
    assert_equal [0, 2000, 4500, 6500], times
  end

  # Integer control values bypass normalization and write raw 0-255
  # (Session.write_dmx's raw path).
  def test_integer_values_write_raw
    session, _audio = new_session
    session.bind_statement(:raw,
                           Johakyu.dmx_builder(:s1).dimmer(Johakyu::Pattern.pure(200)))
    run_until(session, 100)
    assert_equal 200, DMX.get(6)
  end

  def test_remove_statement_stops_future_events
    session, audio = new_session
    session.bind_statement(:drums, Johakyu.sound("bd*4"))
    run_until(session, 1000)
    session.remove_statement(:drums)
    count = audio.plays.length
    run_until(session, 3000)
    assert_equal count, audio.plays.length
  end

  # The sink's third argument carries the event's whole duration, so
  # pitched sinks can schedule the note-off. Two-argument sinks keep
  # working (blocks ignore extra arguments).
  def test_sink_receives_event_duration
    clock = Johakyu::Clock.new(bpm: 120)
    scheduler = Johakyu::Scheduler.new(clock)
    durations = []
    scheduler.bind(:t, Johakyu::Mini.parse("a b")) { |v, at, dur| durations << dur }
    run_until(scheduler, 1100)
    assert_equal [1000, 1000], durations
  end
end
