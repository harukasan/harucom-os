require "picotest"

# Pins the board-parity configuration of the host test VM: the same
# integer width and string encoding as the firmware build, and the
# Machine time stub that tests use to control time.
class VmParityTest < Picotest::Test
  def test_integer_is_64bit
    assert_equal 1099511627776, 1 << 40
  end

  def test_strings_are_utf8
    assert_equal 3, "あいう".length
  end

  def test_machine_time_stub
    Machine.millis = 1234
    assert_equal 1234, Machine.board_millis
  end
end
