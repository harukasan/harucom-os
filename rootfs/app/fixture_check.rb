# fixture_check: M3 verification for the Johakyu fixture model.
#
# Run from IRB:  run app/fixture_check.rb
#
# Verifies the research 03 items on the default rig (two SHEHDS LED
# Spot 80W in 13ch mode, daisy chained, body addresses 001 and 014):
# the manual DMX chart against the real fixture (Sweep), attribute to
# absolute channel resolution by universe readback (Resolve, no eyes
# needed), the address alignment procedure (Identify), the wheel name
# tables (Wheel), and group broadcast with spread (Spread).
#
# Modes:
#   1  Sweep     drive one raw channel at a time, compare with the chart
#   2  Resolve   fixture layer readback assertions, PASS/FAIL on screen
#   3  Identify  light exactly one fixture by patch name
#   4  Wheel     step color/gobo/prism name tables on one fixture
#   5  Spread    group dimmer plus spread pan chase
#   B  Blackout  all slots to zero
#   Q  Quit      blackout, stop the engine, return to IRB

require "johakyu/fixture"

def dmx(name)
  Johakyu.dmx(name)
end

def fixture_check
  keyboard = $keyboard
  patch = Johakyu.patch

  attr_clear  = 0xF0
  attr_normal = 0xF0
  attr_title  = 0x1F
  attr_active = 0xF4
  attr_fail   = 0xF1

  DMX.init
  DMX.start          # clears the universe, first frames are dark
  DMX.deadman_ms = 500
  active_slots = patch.max_channel
  DMX.active_slots = active_slots

  rate_fc = DMX.frame_count
  rate_ms = Machine.board_millis
  rate_text = "--.-"
  status = lambda do |row|
    now = Machine.board_millis
    if now - rate_ms >= 1000
      fc = DMX.frame_count
      hz10 = ((fc - rate_fc) * 10000) / (now - rate_ms)
      rate_text = "#{hz10 / 10}.#{hz10 % 10}"
      rate_fc = fc
      rate_ms = now
    end
    DVI::Text.put_string(0, row, "frames: #{DMX.frame_count}   rate: #{rate_text} Hz   slots: #{active_slots}      ", attr_active)
  end

  back_key = lambda do |k|
    k && (k == Keyboard::ESCAPE || k == Keyboard::CTRL_C)
  end

  # 13ch chart from the manual: [attribute, what to expect on the
  # fixture, safe to auto ramp]. CH12/13 trigger auto programs or a
  # reset, so they start held at 0 and only move on manual keys.
  ch_info = [
    nil,
    ["pan",        "Pan 540 deg, head turns",                true],
    ["pan_fine",   "Pan fine 2 deg, tiny motion",            true],
    ["tilt",       "Tilt 200 deg, head nods",                true],
    ["tilt_fine",  "Tilt fine 2 deg, tiny motion",           true],
    ["speed",      "Pan and tilt speed",                     true],
    ["dimmer",     "Total dimming, brightness follows",      true],
    ["strobe",     "0-15 steady on, 16-251 strobe frequency", true],
    ["color",      "Color wheel, 8 wide bands, 128+ rotates", true],
    ["gobo",       "Gobo wheel, 9 wide bands, 128+ rotates",  true],
    ["focus",      "Pattern focus near to far",              true],
    ["prism",      "0-15 off, 16-127 in, 128-255 rotate",    true],
    ["motor_auto", "16+ runs auto programs (head moves)",    false],
    ["function",   "150-249 auto/sound, 250-255 RESET",      false],
  ]

  # Mode 1: raw channel sweep against the manual chart. The dimmer
  # channel is held at 255 as a beacon so wheel and movement channels
  # are visible while they sweep.
  run_sweep = lambda do
    unit = :s1
    offset = 1
    value = 0
    hold = false
    draw_static = lambda do
      DVI::Text.clear(attr_clear)
      DVI::Text.put_string(0, 0, "Sweep: one raw channel at a time vs the manual chart", attr_title)
      DVI::Text.put_string(0, 2, "f: switch fixture   n/p: next/prev channel   Space: hold/resume", attr_normal)
      DVI::Text.put_string(0, 3, "0/5/9: set 0/128/255   ,/.: step -1/+1   Esc: back", attr_normal)
    end
    draw_static.call
    loop do
      fixture = patch[unit]
      base = fixture.base
      abs = base + offset - 1
      info = ch_info[offset]
      auto = info[2]
      unless hold || !auto
        ph = (Machine.board_millis % 5000).to_f / 5000.0
        tri = ph < 0.5 ? ph * 2.0 : 2.0 - ph * 2.0
        value = (tri * 255.0 + 0.5).to_i
      end
      DMX.set(abs, value)
      # Beacon: keep the beam visible unless the dimmer itself sweeps.
      DMX.set(base + 5, 255) unless offset == 6
      DVI::Text.put_string(0, 5, "fixture: #{unit} (base #{base})    channel: CH#{offset} -> abs #{abs}     ", attr_active)
      DVI::Text.put_string(0, 6, "function: #{info[0]}                          ", attr_normal)
      DVI::Text.put_string(0, 7, "expect:   #{info[1]}                          ", attr_normal)
      mode_text = auto ? (hold ? "HOLD" : "ramp") : "manual only"
      DVI::Text.put_string(0, 9, "value: #{value}   readback: #{DMX.get(abs)}   [#{mode_text}]        ", attr_normal)
      status.call(11)
      DVI::Text.commit
      DMX.keepalive
      k = keyboard.read_char
      break if back_key.call(k)
      if k && k.char
        old_abs = abs
        case k.char
        when "f", "F"
          unit = unit == :s1 ? :s2 : :s1
          DMX.blackout
        when "n", "N"
          DMX.set(old_abs, 0)
          offset = offset >= 13 ? 1 : offset + 1
          value = 0
          hold = !ch_info[offset][2]
        when "p", "P"
          DMX.set(old_abs, 0)
          offset = offset <= 1 ? 13 : offset - 1
          value = 0
          hold = !ch_info[offset][2]
        when " "
          hold = !hold
        when "0"
          value = 0
          hold = true
        when "5"
          value = 128
          hold = true
        when "9"
          value = 255
          hold = true
        when ","
          value = value > 0 ? value - 1 : 0
          hold = true
        when "."
          value = value < 255 ? value + 1 : 255
          hold = true
        end
      end
      sleep_ms 25
    end
    DMX.blackout
  end

  # Mode 2: fixture layer assertions by universe readback. No fixture
  # observation needed; heads may twitch while values are written.
  run_resolve = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Resolve: attribute -> absolute channel, checked via DMX.get", attr_title)
    results = []
    check = lambda do |desc, ok|
      results << [desc, ok]
    end
    expect = lambda do |desc, pairs|
      ok = true
      i = 0
      while i < pairs.length
        ch = pairs[i][0]
        want = pairs[i][1]
        got = DMX.get(ch)
        unless got == want
          ok = false
          desc = "#{desc} (ch#{ch}=#{got} want #{want})"
        end
        i += 1
      end
      results << [desc, ok]
    end

    check.call("patch.max_channel == 26", patch.max_channel == 26)
    check.call("s1 dimmer -> ch6", dmx(:s1).channel(:dimmer) == 6)
    check.call("s2 dimmer -> ch19", dmx(:s2).channel(:dimmer) == 19)

    raised = false
    begin
      dmx(:s1).channel(:laser)
    rescue ArgumentError
      raised = true
    end
    check.call("unknown attribute raises ArgumentError", raised)

    raised = false
    begin
      scratch = Johakyu::Patch.new
      scratch.add(:a, Johakyu::SHEHDS_SPOT_80W_13CH, base: 1)
      scratch.add(:b, Johakyu::SHEHDS_SPOT_80W_13CH, base: 13)
    rescue ArgumentError
      raised = true
    end
    check.call("overlapping patch raises ArgumentError", raised)

    DMX.blackout
    dmx(:s1).pan(0.5)
    expect.call("s1.pan(0.5) -> ch1=128 ch2=0", [[1, 128], [2, 0]])

    DMX.blackout
    dmx(:s2).pan(0.5)
    expect.call("s2.pan(0.5) -> ch14=128, s1 untouched", [[14, 128], [15, 0], [1, 0]])

    DMX.blackout
    dmx(:s1).tilt(1.0)
    expect.call("s1.tilt(1.0) -> ch3=255 ch4=255", [[3, 255], [4, 255]])

    DMX.blackout
    dmx(:s1).dimmer(1.0)
    expect.call("s1.dimmer(1.0) -> ch6=255", [[6, 255]])

    DMX.blackout
    dmx(:s1).strobe(1.0)
    expect.call("s1.strobe(1.0) -> ch7=251", [[7, 251]])
    dmx(:s1).strobe(0.5)
    expect.call("s1.strobe(0.5) -> ch7=134", [[7, 134]])
    dmx(:s1).strobe(0)
    expect.call("s1.strobe(0) -> ch7=0 (steady)", [[7, 0]])

    DMX.blackout
    dmx(:s1).color(:red).gobo(:open).prism(:rotate).focus(0.5)
    expect.call("s1 color/gobo/prism/focus names", [[8, 12], [9, 4], [11, 192], [10, 128]])

    DMX.blackout
    dmx(:all).dimmer(1.0)
    expect.call("all.dimmer(1.0) -> ch6=255 ch19=255", [[6, 255], [19, 255]])

    DMX.blackout
    dmx(:all).spread(1.0).pan(0.0)
    expect.call("all.spread(1.0).pan(0.0) -> s1=0 s2=full", [[1, 0], [2, 0], [14, 255], [15, 255]])

    DMX.blackout
    dmx(:s1).raw(:pan, 200)
    expect.call("s1.raw(:pan, 200) -> ch1=200", [[1, 200]])

    DMX.blackout
    passed = 0
    row = 2
    i = 0
    while i < results.length
      desc = results[i][0]
      ok = results[i][1]
      passed += 1 if ok
      DVI::Text.put_string(0, row, ok ? "PASS  #{desc}" : "FAIL  #{desc}", ok ? attr_normal : attr_fail)
      row += 1
      i += 1
    end
    DVI::Text.put_string(0, row + 1, "#{passed}/#{results.length} passed.   Esc: back to menu", attr_title)
    loop do
      status.call(row + 3)
      DVI::Text.commit
      DMX.keepalive
      break if back_key.call(keyboard.read_char)
      sleep_ms 25
    end
  end

  # Mode 3: address alignment (research 03 step 3). Exactly one patch
  # name lights at a time; the matching physical fixture must respond.
  run_identify = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Identify: light exactly one fixture by patch name", attr_title)
    DVI::Text.put_string(0, 2, "Body menu Addr must match the patch: s1 = 001, s2 = 014.", attr_normal)
    DVI::Text.put_string(0, 3, "The named fixture, and only that one, must light white/open.", attr_normal)
    DVI::Text.put_string(0, 5, "1: s1   2: s2   a: all   0: none   Esc: back", attr_normal)
    lit = "none"
    loop do
      DVI::Text.put_string(0, 7, "lit: #{lit}          ", attr_active)
      status.call(9)
      DVI::Text.commit
      DMX.keepalive
      k = keyboard.read_char
      break if back_key.call(k)
      if k && k.char
        case k.char
        when "1"
          DMX.blackout
          dmx(:s1).dimmer(1.0)
          lit = "s1 (base 1, dimmer ch 6)"
        when "2"
          DMX.blackout
          dmx(:s2).dimmer(1.0)
          lit = "s2 (base 14, dimmer ch 19)"
        when "a", "A"
          DMX.blackout
          dmx(:all).dimmer(1.0)
          lit = "all"
        when "0"
          DMX.blackout
          lit = "none"
        end
      end
      sleep_ms 25
    end
    DMX.blackout
  end

  # Mode 4: wheel name tables. Steps through the color/gobo/prism
  # tables on one fixture; the wheel position must match the name.
  run_wheel = lambda do
    unit = :s1
    colors = Johakyu::SHEHDS_SPOT_80W_COLORS.keys
    gobos = Johakyu::SHEHDS_SPOT_80W_GOBOS.keys
    prisms = Johakyu::SHEHDS_SPOT_80W_PRISMS.keys
    ci = 0
    gi = 0
    pi = 0
    apply = lambda do
      DMX.blackout
      f = dmx(unit)
      f.dimmer(1.0)
      f.color(colors[ci])
      f.gobo(gobos[gi])
      f.prism(prisms[pi])
    end
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Wheel: name tables on one fixture", attr_title)
    DVI::Text.put_string(0, 2, "f: switch fixture   c: next color   g: next gobo   r: next prism", attr_normal)
    DVI::Text.put_string(0, 3, "Esc: back", attr_normal)
    apply.call
    loop do
      f = dmx(unit)
      DVI::Text.put_string(0, 5, "fixture: #{unit}                    ", attr_active)
      DVI::Text.put_string(0, 7, "color: #{colors[ci]} (ch#{f.channel(:color)}=#{DMX.get(f.channel(:color))})          ", attr_normal)
      DVI::Text.put_string(0, 8, "gobo:  #{gobos[gi]} (ch#{f.channel(:gobo)}=#{DMX.get(f.channel(:gobo))})          ", attr_normal)
      DVI::Text.put_string(0, 9, "prism: #{prisms[pi]} (ch#{f.channel(:prism)}=#{DMX.get(f.channel(:prism))})          ", attr_normal)
      status.call(11)
      DVI::Text.commit
      DMX.keepalive
      k = keyboard.read_char
      break if back_key.call(k)
      if k && k.char
        case k.char
        when "f", "F"
          unit = unit == :s1 ? :s2 : :s1
          apply.call
        when "c", "C"
          ci = (ci + 1) % colors.length
          apply.call
        when "g", "G"
          gi = (gi + 1) % gobos.length
          apply.call
        when "r", "R"
          pi = (pi + 1) % prisms.length
          apply.call
        end
      end
      sleep_ms 25
    end
    DMX.blackout
  end

  # Mode 5: group broadcast and spread. Both heads light together and
  # pan as a chase: s2 leads s1 by the spread amount.
  run_spread = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Spread: all.dimmer(1.0), spread(0.5) pan chase", attr_title)
    DVI::Text.put_string(0, 2, "Both fixtures full on; heads sweep offset from each other.", attr_normal)
    DVI::Text.put_string(0, 4, "Esc: back", attr_normal)
    dmx(:all).dimmer(1.0).tilt(0.3)
    loop do
      ph = (Machine.board_millis % 6000).to_f / 6000.0
      tri = ph < 0.5 ? ph * 2.0 : 2.0 - ph * 2.0
      base_pan = tri * 0.5
      dmx(:all).spread(0.5).pan(base_pan)
      DVI::Text.put_string(0, 6, "pan: s1=#{DMX.get(1)}  s2=#{DMX.get(14)}      ", attr_normal)
      status.call(8)
      DVI::Text.commit
      DMX.keepalive
      break if back_key.call(keyboard.read_char)
      sleep_ms 25
    end
    DMX.blackout
  end

  loop do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "=== Fixture check (M3)  SHEHDS Spot 80W x2  13ch  base 1 / 14 ===", attr_title)
    DVI::Text.put_string(0, 2, "Patch: s1=1-13, s2=14-26, group :all, active_slots=#{active_slots}", attr_normal)
    DVI::Text.put_string(0, 4, "Modes:", attr_normal)
    DVI::Text.put_string(2, 5, "1  Sweep     raw channel vs manual chart", attr_normal)
    DVI::Text.put_string(2, 6, "2  Resolve   fixture layer readback assertions", attr_normal)
    DVI::Text.put_string(2, 7, "3  Identify  address alignment, one fixture at a time", attr_normal)
    DVI::Text.put_string(2, 8, "4  Wheel     color/gobo/prism name tables", attr_normal)
    DVI::Text.put_string(2, 9, "5  Spread    group broadcast + pan chase", attr_normal)
    DVI::Text.put_string(2, 10, "B  Blackout  all slots to zero", attr_normal)
    DVI::Text.put_string(2, 11, "Q  Quit      blackout, stop engine, back to IRB", attr_normal)
    DVI::Text.put_string(0, 13, "In a mode, press Esc to come back here.", attr_normal)

    choice = nil
    loop do
      status.call(15)
      DVI::Text.commit
      DMX.keepalive
      k = keyboard.read_char
      if k
        if k == Keyboard::ESCAPE || k == Keyboard::CTRL_C
          choice = :quit
          break
        elsif k.char
          choice = k.char
          break
        end
      end
      sleep_ms 20
    end

    case choice
    when :quit, "q", "Q"
      break
    when "1"
      run_sweep.call
    when "2"
      run_resolve.call
    when "3"
      run_identify.call
    when "4"
      run_wheel.call
    when "5"
      run_spread.call
    when "b", "B"
      DMX.blackout
      DVI::Text.put_string(0, 17, "Blackout sent.", attr_active)
      DVI::Text.commit
      sleep_ms 600
    end
  end

  # Go dark, let the zero frames reach the fixtures, then stop.
  DMX.blackout
  8.times do
    DMX.keepalive
    sleep_ms 25
  end
  DMX.stop
  DVI::Text.clear(attr_clear)
  DVI::Text.commit
  puts "fixture_check: done (engine stopped)."
end

fixture_check
