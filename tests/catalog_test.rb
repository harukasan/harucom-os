require "picotest"
require "johakyu/live"

# The jo/ha/kyu show catalog (/data/johakyu/catalog.rb): forms build
# control patterns and record like the statement sugar.
$LOAD_PATH << "rootfs/data/johakyu"
require "catalog"

class CatalogTest < Picotest::Test
  def setup
    Machine.millis = 0
    DMX.reset
    Johakyu.patch = johakyu_test_patch
    @audio = FakeAudio.new
    @session = Johakyu::Session.new(audio: @audio, bpm: 120, audio_latency_ms: 0)
    @live = Johakyu::Live.new(@session)
    $johakyu_live = @live
    @live.begin_recording
  end

  def run_until(until_ms, step_ms = 10)
    t = Machine.board_millis
    while t <= until_ms
      Machine.millis = t
      @session.update
      t += 10
    end
  end

  def test_jo_sound_form_records_and_plays
    jo("kick4")
    @live.apply
    run_until(1900)
    # bd*4 at 2000 ms/cycle: every 500 ms, channel 3
    plays = @audio.plays
    assert_equal true, plays.length >= 4
    assert_equal 3, plays[0][2]
    assert_equal 25_000, plays[1][1]
  end

  def test_jo_light_form_targets_all
    jo("dimmer_beat")
    @live.apply
    run_until(100)
    channels = DMX.writes.map { |w| w[1] }
    assert_equal true, channels.include?(6)
    assert_equal true, channels.include?(19)
  end

  def test_catalog_inside_track_block_returns_pattern
    track(:beat) { jo("heartbeat") }
    @live.apply
    names = @session.scheduler.track_names
    assert_equal [:beat], names
  end

  def test_ha_circle_emits_pan_and_tilt
    haps = JOHAKYU_HA["circle"].call(on: :s1).query_arc(0, 1)
    pans = 0
    tilts = 0
    i = 0
    while i < haps.length
      value = haps[i].value
      pans += 1 if value[:pan]
      tilts += 1 if value[:tilt]
      assert_equal :s1, value[:target].name
      i += 1
    end
    assert_equal true, pans >= 16
    assert_equal true, tilts >= 16
  end

  def test_kyu_finale_stacks_controls
    haps = JOHAKYU_KYU["finale"].call({}).query_arc(0, 1)
    keys = {}
    i = 0
    while i < haps.length
      value = haps[i].value
      keys[:dimmer] = true if value[:dimmer]
      keys[:strobe] = true if value[:strobe]
      keys[:color] = true if value[:color]
      i += 1
    end
    assert_equal true, keys[:dimmer] && keys[:strobe] && keys[:color]
  end

  def test_unknown_form_raises
    assert_raise(ArgumentError) do
      jo("nope")
    end
  end
end
