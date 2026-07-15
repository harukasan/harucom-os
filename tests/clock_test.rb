require "picotest"
require "johakyu/clock"

# Johakyu::Clock reads Machine.board_millis only, so tests drive time
# through the Machine.millis= stub. All expectations use values that
# are exact in binary floating point.
class ClockTest < Picotest::Test
  def setup
    Machine.millis = 0
  end

  def test_position_advances_with_time
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4) # 2000 ms/cycle
    assert_equal 0.0, clock.position
    Machine.millis = 1000
    assert_equal 0.5, clock.position
    Machine.millis = 2000
    assert_equal 1.0, clock.position
  end

  def test_position_to_ms_is_the_inverse
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4)
    assert_equal 3000.0, clock.position_to_ms(1.5)
    assert_equal 1000.0, clock.position_to_ms(Rational(1, 2))
  end

  def test_tempo_change_keeps_position_continuous
    clock = Johakyu::Clock.new(bpm: 120, beats_per_cycle: 4)
    Machine.millis = 1000 # position 0.5
    clock.bpm = 240       # 1000 ms/cycle from here on
    assert_equal 0.5, clock.position
    Machine.millis = 1500
    assert_equal 1.0, clock.position
  end

  def test_cpm_and_cps_set_the_cycle_length
    clock = Johakyu::Clock.new
    clock.cpm = 60 # one cycle per second
    assert_equal 1000.0, clock.ms_per_cycle
    clock.cps = 2.0
    assert_equal 500.0, clock.ms_per_cycle
    assert_equal 480.0, clock.bpm
  end
end
