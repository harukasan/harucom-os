require "picotest"
require "johakyu/live"

# Live coding layer: eval scripts record tracks through the top-level
# DSL, apply replays onto the running session with replace semantics.
# track(:name) blocks are the primary form (strudel-rb compatible);
# bare statements take anonymous slots :t1, :t2 in order.
class LiveTest < Picotest::Test
  def setup
    Machine.millis = 0
    DMX.reset
    Johakyu.patch = johakyu_test_patch
    @audio = FakeAudio.new
    @session = Johakyu::Session.new(audio: @audio, bpm: 120, audio_latency_ms: 0)
    @live = Johakyu::Live.new(@session)
    $johakyu_live = @live
  end

  def run_until(until_ms, step_ms = 10)
    t = Machine.board_millis
    while t <= until_ms
      Machine.millis = t
      @session.update
      t += step_ms
    end
  end

  def play_ms(audio)
    audio.plays.map { |e| e[1] / 50 }
  end

  def test_named_track_drives_session
    @live.begin_recording
    track(:drums) { sound("bd ~ sd ~").dimmer(1.0).on(:s1) }
    assert_equal 0, @audio.plays.length
    assert_equal 0, DMX.writes.length
    assert_equal true, @live.apply
    run_until(1900)
    # the 2000 kick reserves early (RESERVE_LEAD_MS before its target);
    # the 2000 light write waits in the due list until its target
    assert_equal [0, 1000, 2000], play_ms(@audio)
    dimmers = DMX.writes.select { |w| w[1] == 6 && w[2] == 255 }.map { |w| w[0] }
    assert_equal [0, 1000], dimmers
  end

  def test_bare_statement_takes_anonymous_slot
    @live.begin_recording
    sound("bd*2")
    @live.apply
    assert_equal true, @session.scheduler.track_names.include?(:t1)
    # one cycle is 2000 ms at bpm 120 (4 beats), so bd*2 hits every
    # 1000; the 2000 hit reserves early (RESERVE_LEAD_MS)
    run_until(1900)
    assert_equal [0, 1000, 2000], play_ms(@audio)
  end

  def test_bare_chain_updates_its_slot
    @live.begin_recording
    sound("bd sd").rev
    @live.apply
    run_until(1990)
    plays = @audio.plays
    # rev holds from the first cycle: snare (ch 4) first, kick second
    assert_equal 4, plays[0][2]
    assert_equal 3, plays[1][2]
  end

  def test_bare_chain_attaches_controls
    @live.begin_recording
    sound("bd").color("red")
    @live.apply
    run_until(200)
    # the light rides the kick on the default :all group: red lands
    # on both color channels (s1 ch8, s2 ch21)
    reds = DMX.writes.select { |w| w[2] == 12 }.map { |w| w[1] }
    assert_equal [8, 21], reds
  end

  def test_sugar_inside_track_block_stays_pure
    @live.begin_recording
    track(:one) { sound("bd") }
    sound("sd")
    @live.apply
    names = @session.scheduler.track_names
    assert_equal true, names.include?(:one)
    assert_equal true, names.include?(:t1)
    assert_equal 2, names.length
  end

  def test_muted_track_binds_silence_under_its_name
    @live.begin_recording
    _track(:drums) { sound("bd*4") }
    @live.apply
    assert_equal true, @session.scheduler.track_names.include?(:drums)
    run_until(1990)
    assert_equal 0, @audio.plays.length
  end

  def test_signals_work_in_scripts
    @live.begin_recording
    dmx(:s2).pan(sine.range(0.2, 0.8).slow(8))
    @live.apply
    run_until(500, 20)
    pans = DMX.writes.select { |w| w[1] == 14 }
    # the default segment(8) yields a write every 250 ms
    assert_equal true, pans.length >= 2
  end

  def test_tempo_records_and_applies
    @live.begin_recording
    tempo(240)
    track(:drums) { sound("bd") }
    @live.apply
    assert_equal 240, @session.clock.bpm
  end

  def test_audio_latency_records_and_applies
    @live.begin_recording
    audio_latency(25)
    track(:drums) { sound("bd") }
    @live.apply
    assert_equal 25, @session.audio_latency_ms
  end

  # Every generated top-level statement records a bare slot under its
  # own key.
  def test_every_top_level_control_records
    @live.begin_recording
    Johakyu::LIGHT_CONTROLS.each { |key| send(key, "1").on(:s1) }
    @live.apply
    assert_equal Johakyu::LIGHT_CONTROLS.length,
                 @session.scheduler.track_names.length
  end

  def test_replace_removes_stale_tracks
    @live.begin_recording
    track(:drums) { sound("bd*4") }
    track(:wash) { dimmer("1").on(:s1) }
    @live.apply
    run_until(1000)
    @live.begin_recording
    track(:drums) { sound("bd*2") }
    @live.apply
    run_until(1100)
    names = @session.scheduler.track_names
    assert_equal true, names.include?(:drums)
    assert_equal false, names.include?(:wash)
  end

  def test_empty_recording_silences_everything
    @live.begin_recording
    track(:drums) { sound("bd*4") }
    @live.apply
    run_until(1000)
    count = @audio.plays.length
    @live.begin_recording
    @live.apply
    run_until(3000)
    assert_equal count, @audio.plays.length
    assert_equal 0, @session.scheduler.track_names.length
  end

  def test_discard_drops_recording
    @live.begin_recording
    track(:drums) { sound("bd*4") }
    @live.discard
    assert_equal false, @live.apply
    run_until(500)
    assert_equal 0, @audio.plays.length
  end

  def test_unknown_fixture_raises_at_record_time
    @live.begin_recording
    raised = false
    begin
      track(:bad) { dimmer("1").on(:nope) }
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  def test_fixture_statements_swap_the_patch
    @live.begin_recording
    fixture(:m1, JOHAKYU_TEST_FIXTURE, mode: "13ch", address: 40)
    group(:rig, :m1)
    # Later statements resolve against the pending rig, so one eval
    # patches fixtures and targets them.
    track(:x) { dimmer("1").on(:m1) }
    @live.apply
    assert_equal 45, Johakyu.dmx(:m1).channel(:dimmer)
    assert_equal 52, $dmx_active_slots
    assert_raise(ArgumentError) { Johakyu.dmx(:s1) }
    run_until(400)
    assert_equal 255, DMX.get(45)
  end

  def test_recording_without_fixtures_keeps_the_patch
    patch_before = Johakyu.patch
    @live.begin_recording
    track(:drums) { sound("bd*4") }
    @live.apply
    assert_equal true, Johakyu.patch.equal?(patch_before)
    assert_equal nil, $dmx_active_slots
  end

  def test_discard_restores_the_resolution_context
    @live.begin_recording
    fixture(:m2, JOHAKYU_TEST_FIXTURE, mode: "13ch", address: 40)
    @live.discard
    assert_raise(ArgumentError) { Johakyu.dmx(:m2) }
    assert_equal 6, Johakyu.dmx(:s1).channel(:dimmer)
  end

  def test_group_before_fixture_raises
    @live.begin_recording
    assert_raise(ArgumentError) { group(:rig, :s1) }
  end

  def test_track_block_must_return_a_pattern
    @live.begin_recording
    assert_raise(ArgumentError) do
      track(:bad) { 42 }
    end
  end
end
