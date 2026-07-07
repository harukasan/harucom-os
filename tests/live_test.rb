require "picotest"
require "johakyu/live"

# Live coding layer: eval scripts record through the top-level DSL,
# apply replays onto the running session with replace semantics.
class LiveTest < Picotest::Test
  def setup
    Machine.millis = 0
    DMX.reset
    Johakyu.patch = Johakyu.default_patch
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

  def test_recorded_script_drives_session
    @live.begin_recording
    sound("bd ~ sn ~")
    dmx(:s1).dimmer("1 0")
    assert_equal 0, @audio.tones.length
    assert_equal 0, DMX.writes.length
    assert_equal true, @live.apply
    run_until(1990)
    assert_equal [0, 1000], @audio.tones.map { |e| e[1] }
    dimmers = DMX.writes.select { |w| w[1] == 6 }.map { |w| [w[0], w[2]] }
    assert_equal [[0, 255], [1000, 0]], dimmers
  end

  def test_sound_chain_records_transforms
    @live.begin_recording
    sound("bd sn").rev
    @live.apply
    run_until(1990)
    assert_equal 1, @audio.tones[0][2]
    assert_equal 0, @audio.tones[1][2]
  end

  def test_signals_work_in_scripts
    @live.begin_recording
    dmx(:s2).pan(sine.range(0.2, 0.8).slow(8))
    @live.apply
    run_until(500, 20)
    pans = DMX.writes.select { |w| w[1] == 14 }
    assert_equal true, pans.length >= 10
  end

  def test_tempo_records_and_applies
    @live.begin_recording
    tempo 240
    @live.apply
    assert_equal 240, @session.clock.bpm
  end

  def test_replace_removes_stale_tracks
    @live.begin_recording
    sound("bd*4")
    dmx(:s1).dimmer("1 0")
    @live.apply
    run_until(1000)
    @live.begin_recording
    sound("bd*4")
    @live.apply
    assert_equal false, @session.scheduler.track_names.include?(:dmx_s1_dimmer)
    assert_equal true, @session.scheduler.track_names.include?(:sound)
  end

  def test_empty_recording_silences_everything
    @live.begin_recording
    sound("bd*4")
    @live.apply
    run_until(1000)
    tones_before = @audio.tones.length
    @live.begin_recording
    @live.apply
    # the silence swap lands at the cycle boundary (2000 ms)
    run_until(4000)
    after_boundary = @audio.tones.select { |e| e[1] >= 2000 }
    assert_equal 0, after_boundary.length
    assert_equal true, @audio.tones.length > tones_before
  end

  def test_discard_drops_recording
    @live.begin_recording
    sound("bd*4")
    @live.discard
    assert_equal false, @live.apply
    run_until(500)
    assert_equal 0, @audio.tones.length
  end

  def test_unknown_fixture_raises_at_record_time
    @live.begin_recording
    assert_raise(ArgumentError) { dmx(:nope) }
  end
end
