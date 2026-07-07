require "picotest"
require "johakyu/mini"

# Mini notation semantics. Expectations were verified against
# strudel-rb's Mini::Parser with a host diff (research 05); these tests
# pin the behavior on the actual microruby VM.
class MiniTest < Picotest::Test
  def parse(text)
    Johakyu::Mini.parse(text)
  end

  def test_sequence_with_rests
    assert_equal ["0/1..1/4|0/1..1/4|\"bd\"", "1/2..3/4|1/2..3/4|\"sn\""],
                 hap_sigs(parse("bd ~ sn -").query_arc(0, 1))
  end

  def test_fast_element
    assert_equal ["0/1..1/4|0/1..1/4|\"bd\"", "1/4..1/2|1/4..1/2|\"bd\"",
                  "1/2..1/1|1/2..1/1|\"sn\""],
                 hap_sigs(parse("bd*2 sn").query_arc(0, 1))
  end

  def test_replicate
    assert_equal ["0/1..1/4|0/1..1/4|\"bd\"", "1/4..1/2|1/4..1/2|\"bd\"",
                  "1/2..3/4|1/2..3/4|\"bd\"", "3/4..1/1|3/4..1/1|\"sn\""],
                 hap_sigs(parse("bd!3 sn").query_arc(0, 1))
  end

  def test_slow_element
    assert_equal ["0/1..2/1|0/1..1/1|\"bd\""], hap_sigs(parse("bd/2").query_arc(0, 1))
    assert_equal ["0/1..2/1|1/1..2/1|\"bd\""], hap_sigs(parse("bd/2").query_arc(1, 2))
  end

  def test_group
    assert_equal ["0/1..1/4|0/1..1/4|\"bd\"", "1/4..1/2|1/4..1/2|\"hh\"",
                  "1/2..1/1|1/2..1/1|\"sn\""],
                 hap_sigs(parse("[bd hh] sn").query_arc(0, 1))
  end

  def test_angle_selects_per_cycle
    assert_equal ["0/1..1/1|0/1..1/1|\"a\"", "1/1..2/1|1/1..2/1|\"b\"",
                  "2/1..3/1|2/1..3/1|\"c\"", "3/1..4/1|3/1..4/1|\"a\""],
                 hap_sigs(parse("<a b c>").query_arc(0, 4))
  end

  def test_stack
    assert_equal ["0/1..1/1|0/1..1/1|\"bd\"",
                  "0/1..1/4|0/1..1/4|\"hh\"", "1/4..1/2|1/4..1/2|\"hh\"",
                  "1/2..3/4|1/2..3/4|\"hh\"", "3/4..1/1|3/4..1/1|\"hh\""],
                 hap_sigs(parse("bd, hh*4").query_arc(0, 1))
  end

  def test_sample_number
    haps = parse("bd:2").query_arc(0, 1)
    assert_equal "bd", haps[0].value[:s]
    assert_equal 2, haps[0].value[:n]
  end

  def test_hold_extends_previous
    assert_equal ["0/1..1/2|0/1..1/2|\"bd\"", "3/4..1/1|3/4..1/1|\"sn\""],
                 hap_sigs(parse("bd _ ~ sn").query_arc(0, 1))
  end

  def test_hold_in_angle_repeats_previous_cycle
    assert_equal ["0/1..1/1|0/1..1/1|\"a\"", "1/1..2/1|1/1..2/1|\"a\"",
                  "2/1..3/1|2/1..3/1|\"b\""],
                 hap_sigs(parse("<a _ b>").query_arc(0, 3))
  end

  def test_underscore_names_are_atoms
    assert_equal ["0/1..1/2|0/1..1/2|\"light_blue\"", "1/2..1/1|1/2..1/1|\"white\""],
                 hap_sigs(parse("light_blue white").query_arc(0, 1))
  end

  def test_reify_hooks_strings
    pattern = Johakyu::Pattern.reify("bd sn")
    assert_equal 2, pattern.query_arc(0, 1).length
  end

  def test_mini_shorthand_allows_transform_chains
    haps = Johakyu.mini("bd sn").fast(2).query_arc(0, 1)
    assert_equal 4, haps.length
  end

  def test_string_zero_is_false_in_bool_patterns
    masked = Johakyu::Pattern.fastcat(1, 2).mask("1 0").query_arc(0, 1)
    assert_equal ["0/1..1/2|0/1..1/2|1"], hap_sigs(masked)
    structed = Johakyu::Pattern.pure("bd").struct("1 0 1 0").query_arc(0, 1)
    assert_equal ["0/1..1/4|0/1..1/4|\"bd\"", "1/2..3/4|1/2..3/4|\"bd\""],
                 hap_sigs(structed)
  end

  def test_malformed_input_raises
    assert_raise(ArgumentError) { parse("[bd") }
    assert_raise(ArgumentError) { parse("bd ]") }
  end

  def test_repeated_and_partial_queries_are_stable
    pattern = parse("<bd sn> hh")
    first = hap_sigs(pattern.query_arc(0, 1))
    # same cycle again (memo hit), then halves, then the next cycle
    assert_equal first, hap_sigs(pattern.query_arc(0, 1))
    halves = hap_sigs(pattern.query_arc(0, 0.5)) + hap_sigs(pattern.query_arc(0.5, 1))
    assert_equal first, halves
    assert_equal ["1/1..3/2|1/1..3/2|\"sn\"", "3/2..2/1|3/2..2/1|\"hh\""],
                 hap_sigs(pattern.query_arc(1, 2))
  end
end
