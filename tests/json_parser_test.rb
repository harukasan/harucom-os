require "picotest"
require "dmx/json_parser"

# DMX::JSONParser is the byte-indexed replacement for the stdlib JSON
# parser on the fixture load path. The stdlib gem stays in the VM, so
# every case is checked against JSON.parse as the reference.
class JsonParserTest < Picotest::Test
  def both(text)
    [DMX::JSONParser.parse(text), JSON.parse(text)]
  end

  def assert_matches_stdlib(text)
    ours, reference = both(text)
    assert_equal reference, ours
  end

  def test_scalars
    assert_matches_stdlib '"hello"'
    assert_matches_stdlib "42"
    assert_matches_stdlib "-17"
    assert_matches_stdlib "3.5"
    assert_matches_stdlib "-0.25"
    assert_matches_stdlib "1e3"
    assert_matches_stdlib "2.5E-2"
    assert_matches_stdlib "true"
    assert_matches_stdlib "false"
    assert_equal nil, DMX::JSONParser.parse("null")
  end

  def test_containers
    assert_matches_stdlib "{}"
    assert_matches_stdlib "[]"
    assert_matches_stdlib '[1, 2, 3]'
    assert_matches_stdlib '{"a": 1, "b": [true, null], "c": {"d": "e"}}'
    assert_matches_stdlib "  [ 1 ,\n\t2 ]  "
  end

  def test_string_escapes
    assert_matches_stdlib '"a\\"b"'
    assert_matches_stdlib '"line\\nbreak\\ttab"'
    assert_matches_stdlib '"back\\\\slash \\/ slash"'
    assert_equal "A", DMX::JSONParser.parse('"\\u0041"')
    assert_equal "é", DMX::JSONParser.parse('"\\u00e9"')
  end

  def test_multibyte_passthrough
    assert_equal "日本語", DMX::JSONParser.parse('"日本語"')
    assert_matches_stdlib '{"名前": "灯体"}'
  end

  def test_shipped_fixture_matches_stdlib
    text = File.open("rootfs/data/dmx/fixtures/shehds_80w_led_spot_light.json", "r") { |f| f.read }
    assert_matches_stdlib text
  end

  def test_malformed_raises
    ["", "{", '{"a"', '{"a":1', "[1,", '"open', "tru", "{1: 2}", "[1] x"].each do |bad|
      raised = false
      begin
        DMX::JSONParser.parse(bad)
      rescue ArgumentError
        raised = true
      end
      assert_equal true, raised
    end
  end
end
