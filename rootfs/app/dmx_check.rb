# dmx_check: M2c smoke test for the picoruby-dmx background engine.
#
# Run from IRB:  run app/dmx_check.rb
#
# Exercises the DMX C API directly against the research 01 checklist:
# background 40 Hz refresh, set / set_range, active_slots, blackout,
# the frame collision guard, and the keepalive dead-man. The frame
# counter and measured refresh rate stay on screen in every mode, and
# the screen updating plus keys responding while 512 slots stream out
# is itself a checklist item (Core 0 is not blocked).
#
# Bench fixture: SHEHDS LED Spot 80W (3-face prism), 13ch mode, DMX
# address 1. CH1 = pan, CH6 = total dimming. Strobe (CH7) below 16 is
# steady on and color/gobo (CH8/CH9) are white/open at 0, so only the
# dimmer needs a value to get light.
#
# Modes:
#   1  Ramp      fade dimmer 0 -> 255 -> 0 with DMX.set
#   2  Range     pan sweep with DMX.set_range while the dimmer holds
#   3  Slots     switch active_slots 512/160/26, watch the frame rate
#   4  Pattern   hold slots 1..8 at FF 00 55 AA FF 00 0F F0 (logic analyzer)
#   5  Deadman   stop keepalive, rig goes dark, any key resumes
#   B  Blackout  all slots to zero
#   Q  Quit      blackout, stop the engine, return to IRB

def dmx_check(dimmer_ch: 6, pan_ch: 1)
  keyboard = $keyboard

  attr_clear  = 0xF0
  attr_normal = 0xF0
  attr_title  = 0x1F
  attr_active = 0xF4

  DMX.init
  DMX.start          # clears the universe, first frames are dark
  DMX.deadman_ms = 500
  active_slots = 512
  DMX.active_slots = active_slots

  # Measured refresh rate over roughly 1 s windows. 512 slots at 40 Hz
  # should read close to 40.0; a lower rate means frames were skipped
  # by the collision guard.
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

  # Mode 1: dimmer ramp via DMX.set. Confirms set values reach the
  # fixture and the engine refreshes without Ruby pacing the UART.
  run_ramp = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Ramp: DMX.set(#{dimmer_ch}, v) fading 0 -> 255 -> 0", attr_title)
    DVI::Text.put_string(0, 2, "The fixture dimmer should fade smoothly at 40 Hz refresh.", attr_normal)
    DVI::Text.put_string(0, 4, "Esc: back to menu", attr_normal)
    value = 0
    step = 3
    loop do
      DMX.set(dimmer_ch, value)
      value += step
      if value >= 255
        value = 255
        step = -3
      elsif value <= 0
        value = 0
        step = 3
      end
      bars = value / 8
      meter = ("#" * bars) + ("." * (32 - bars))
      DVI::Text.put_string(0, 6, "dimmer ch #{dimmer_ch} = #{value}    [#{meter}]   ", attr_normal)
      DVI::Text.put_string(0, 8, "readback DMX.get(#{dimmer_ch}) = #{DMX.get(dimmer_ch)}    ", attr_normal)
      status.call(10)
      DVI::Text.commit
      DMX.keepalive
      break if back_key.call(keyboard.read_char)
      sleep_ms 25
    end
  end

  # Mode 2: pan sweep via DMX.set_range. Writes ch1..6 in one call
  # (pan + zeros + dimmer), confirming consecutive slot writes decode.
  run_range = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Range: DMX.set_range(#{pan_ch}, [pan, 0, 0, 0, 0, 255])", attr_title)
    DVI::Text.put_string(0, 2, "The head should sweep while the dimmer stays full on.", attr_normal)
    DVI::Text.put_string(0, 4, "Esc: back to menu", attr_normal)
    pan = 0
    step = 2
    loop do
      DMX.set_range(pan_ch, [pan, 0, 0, 0, 0, 255])
      pan += step
      if pan >= 255
        pan = 255
        step = -2
      elsif pan <= 0
        pan = 0
        step = 2
      end
      DVI::Text.put_string(0, 6, "pan ch #{pan_ch} = #{pan}     dimmer ch #{dimmer_ch} = #{DMX.get(dimmer_ch)}   ", attr_normal)
      status.call(8)
      DVI::Text.commit
      DMX.keepalive
      break if back_key.call(keyboard.read_char)
      sleep_ms 25
    end
  end

  # Mode 3: active_slots vs frame rate. All sizes should hold 40 Hz;
  # 512 slots (about 22.8 ms of data) is the tight case for the
  # collision guard. The frame gets shorter on the analyzer.
  run_slots = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Slots: DMX.active_slots = 512 / 160 / 26", attr_title)
    DVI::Text.put_string(0, 2, "1: 512 slots (22.8 ms frame, tight at 40 Hz)", attr_normal)
    DVI::Text.put_string(0, 3, "2: 160 slots ( 7.3 ms frame)", attr_normal)
    DVI::Text.put_string(0, 4, "3:  26 slots ( 1.4 ms frame)", attr_normal)
    DVI::Text.put_string(0, 6, "Rate should hold near 40.0 Hz in every case. A drop to", attr_normal)
    DVI::Text.put_string(0, 7, "30 Hz means the guard skipped colliding frames.", attr_normal)
    DVI::Text.put_string(0, 9, "Esc: back to menu", attr_normal)
    DMX.set(dimmer_ch, 128)
    loop do
      k = keyboard.read_char
      break if back_key.call(k)
      if k && k.char
        case k.char
        when "1" then active_slots = 512
        when "2" then active_slots = 160
        when "3" then active_slots = 26
        end
        DMX.active_slots = active_slots
      end
      status.call(11)
      DVI::Text.commit
      DMX.keepalive
      sleep_ms 20
    end
  end

  # Mode 4: fixed pattern for the logic analyzer. BREAK 176 us, MAB
  # 12 us, start code 0x00, then FF 00 55 AA FF 00 0F F0 at 44 us/byte.
  # CH1 = 0xFF swings the pan, so expect the head to move.
  run_pattern = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Pattern: slots 1..8 = FF 00 55 AA FF 00 0F F0", attr_title)
    DVI::Text.put_string(0, 2, "Check on the analyzer: BREAK >= 88 us (176 us nominal),", attr_normal)
    DVI::Text.put_string(0, 3, "MAB >= 8 us, start code 0x00, 44 us/byte at 250 kbaud.", attr_normal)
    DVI::Text.put_string(0, 5, "Note: CH1 = 0xFF turns the pan; blackout on exit.", attr_normal)
    DVI::Text.put_string(0, 7, "Esc: back to menu", attr_normal)
    DMX.set_range(1, [0xFF, 0x00, 0x55, 0xAA, 0xFF, 0x00, 0x0F, 0xF0])
    loop do
      status.call(9)
      DVI::Text.commit
      DMX.keepalive
      break if back_key.call(keyboard.read_char)
      sleep_ms 20
    end
    DMX.blackout
  end

  # Mode 5: dead-man. Keepalive stops while the UI keeps running. The
  # engine must force the rig dark after deadman_ms on its own, and the
  # universe readback drops to 0. Any key toggles the heartbeat back on,
  # which relights the fixture until paused again.
  run_deadman = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Deadman: keepalive paused (deadman_ms = 500)", attr_title)
    DVI::Text.put_string(0, 2, "Dimmer is set to 255 but keepalive is NOT called.", attr_normal)
    DVI::Text.put_string(0, 3, "The rig must go dark by itself after about 500 ms while", attr_normal)
    DVI::Text.put_string(0, 4, "frames keep streaming (frame counter keeps counting).", attr_normal)
    DVI::Text.put_string(0, 6, "Any key: toggle keepalive pause/resume    Esc: back", attr_normal)
    DMX.keepalive
    DMX.set(dimmer_ch, 255)
    resumed = false
    phase_at = Machine.board_millis
    loop do
      elapsed = Machine.board_millis - phase_at
      if resumed
        # Heartbeat restored: the fixture must come back on and stay on.
        DMX.keepalive
        DMX.set(dimmer_ch, 255)
        DVI::Text.put_string(0, 8, "keepalive RESUMED #{elapsed} ms ago, light stays on         ", attr_active)
      else
        # No DMX.keepalive here: this is the point of the test.
        DVI::Text.put_string(0, 8, "keepalive PAUSED for #{elapsed} ms, dark after ~500 ms      ", attr_normal)
      end
      DVI::Text.put_string(0, 9, "readback DMX.get(#{dimmer_ch}) = #{DMX.get(dimmer_ch)}      ", attr_normal)
      status.call(11)
      DVI::Text.commit
      k = keyboard.read_char
      if k
        break if back_key.call(k)
        resumed = !resumed
        DMX.set(dimmer_ch, 255) unless resumed
        phase_at = Machine.board_millis
      end
      sleep_ms 50
    end
  end

  loop do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "=== DMX check (M2c)  UART1 250k 8N2  TX=GPIO20  40 Hz DMA ===", attr_title)
    DVI::Text.put_string(0, 2, "Fixture: dimmer ch #{dimmer_ch}, pan ch #{pan_ch} (SHEHDS 13ch, address 1)", attr_normal)
    DVI::Text.put_string(0, 4, "Modes:", attr_normal)
    DVI::Text.put_string(2, 5, "1  Ramp      fade dimmer with DMX.set", attr_normal)
    DVI::Text.put_string(2, 6, "2  Range     pan sweep with DMX.set_range", attr_normal)
    DVI::Text.put_string(2, 7, "3  Slots     active_slots vs frame rate", attr_normal)
    DVI::Text.put_string(2, 8, "4  Pattern   fixed slots for the logic analyzer", attr_normal)
    DVI::Text.put_string(2, 9, "5  Deadman   pause keepalive, rig must go dark", attr_normal)
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
      run_ramp.call
    when "2"
      run_range.call
    when "3"
      run_slots.call
    when "4"
      run_pattern.call
    when "5"
      run_deadman.call
    when "b", "B"
      DMX.blackout
      DVI::Text.put_string(0, 17, "Blackout sent.", attr_active)
      DVI::Text.commit
      sleep_ms 600
    end
  end

  # Go dark, let the zero frames reach the fixtures, then stop.
  DMX.blackout
  frames_before = DMX.frame_count
  8.times do
    DMX.keepalive
    sleep_ms 25
  end
  frames_sent = DMX.frame_count - frames_before
  DMX.stop
  DVI::Text.clear(attr_clear)
  DVI::Text.commit
  puts "dmx_check: done (#{frames_sent} zero frames sent, engine stopped)."
end

dmx_check(dimmer_ch: 6, pan_ch: 1)
