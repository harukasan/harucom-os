require "picotest"
require "dmx/fixture"

# DMX::Fixture reads the Open Fixture Library JSON format (a tolerant
# subset). Inline documents pin the loader behavior; the shipped SHEHDS
# definition keeps the file and the loader in sync.
class DmxFixtureTest < Picotest::Test
  MINIMAL = '{"name":"L","availableChannels":' \
            '{"Dimmer":{"capability":{"type":"Intensity"}}},' \
            '"modes":[{"shortName":"1ch","channels":["Dimmer"]}]}'

  def test_minimal_document
    fixture = DMX::Fixture.parse(MINIMAL)
    assert_equal "L", fixture[:name]
    assert_equal 1, fixture[:modes].length
    mode = fixture[:modes][0]
    assert_equal "1ch", mode[:label]
    assert_equal 1, mode[:channels].length
    assert_equal "Dimmer", mode[:channels][0][:name]
    assert_equal [[0, 255, "Intensity", "Intensity"]], mode[:channels][0][:caps]
  end

  def test_capability_bands_and_labels
    fixture = DMX::Fixture.parse('{"availableChannels":{"Strobe":{
      "defaultValue": 300,
      "capabilities": [
        {"dmxRange": [0, 15], "type": "ShutterStrobe", "shutterEffect": "Open"},
        {"dmxRange": [16, 251], "type": "ShutterStrobe", "shutterEffect": "Strobe",
         "speedStart": "slow", "speedEnd": "fast"},
        {"dmxRange": [252, 254], "comment": "open again"},
        {"dmxRange": [255, 255], "type": "Effect", "effectName": "Sound control"}
      ]}},
      "modes":[{"name":"only","channels":["Strobe"]}]}')
    channel = fixture[:modes][0][:channels][0]
    assert_equal 255, channel[:default]
    assert_equal [0, 15, "Open", "ShutterStrobe"], channel[:caps][0]
    assert_equal [16, 251, "Strobe slow..fast", "ShutterStrobe"], channel[:caps][1]
    assert_equal [252, 254, "open again", ""], channel[:caps][2]
    assert_equal [255, 255, "Sound control", "Effect"], channel[:caps][3]
    assert_equal "only", fixture[:modes][0][:label]
  end

  def test_fine_channel_aliases
    fixture = DMX::Fixture.parse('{"availableChannels":{"Pan":{
      "fineChannelAliases": ["Pan fine"],
      "capability": {"type": "Pan"}}},
      "modes":[{"shortName":"2ch","channels":["Pan", "Pan fine"]}]}')
    channels = fixture[:modes][0][:channels]
    assert_equal "Pan fine", channels[1][:name]
    assert_equal [], channels[1][:caps]
    assert_equal 0, channels[1][:default]
  end

  def test_unknown_keys_and_unresolved_channels
    # Extra keys anywhere are ignored; a channel key without a
    # definition (e.g. a matrix template reference) still yields a
    # named entry so the fader stays usable.
    fixture = DMX::Fixture.parse('{"name":"X","physical":{"power":80},
      "availableChannels":{"Dimmer":{"capability":{"type":"Intensity"},"highlightValue":255}},
      "modes":[{"shortName":"m","channels":["Dimmer", "Red 1", null]}]}')
    channels = fixture[:modes][0][:channels]
    assert_equal 3, channels.length
    assert_equal "Red 1", channels[1][:name]
    assert_equal [], channels[1][:caps]
    assert_equal nil, channels[2][:name]
  end

  def test_unusable_documents
    assert_equal nil, DMX::Fixture.parse("not json at all")
    assert_equal nil, DMX::Fixture.parse('{"name":"no sections"}')
    assert_equal nil, DMX::Fixture.parse('{"availableChannels":{},"modes":[]}')
    assert_equal nil, DMX::Fixture.read("/no/such/file.json")
  end

  def test_shipped_shehds_definition
    fixture = DMX::Fixture.read("rootfs/data/dmx/fixtures/shehds_80w_led_spot_light.json")
    assert_equal "SHEHDS 80W LED Spot Light", fixture[:name]
    assert_equal 2, fixture[:modes].length

    mode13 = fixture[:modes][0]
    assert_equal "13ch", mode13[:label]
    assert_equal 13, mode13[:channels].length
    assert_equal "Dimmer", mode13[:channels][5][:name]
    assert_equal "Pan fine", mode13[:channels][1][:name]
    strobe = mode13[:channels][6]
    assert_equal [16, 251, "Strobe slow..fast", "ShutterStrobe"], strobe[:caps][1]

    mode10 = fixture[:modes][1]
    assert_equal "10ch", mode10[:label]
    assert_equal 10, mode10[:channels].length
  end
end
