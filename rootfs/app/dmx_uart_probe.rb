# dmx_uart_probe: disposable M0/M1 bringup probe for DMX over UART1.
#
# Run from IRB:  run app/dmx_uart_probe.rb
#
# Drives DMX512 out UART1 TX (GPIO20) -> Grove(J5) -> M5 DMX Unit (yellow /
# UART_RX) at 250000 baud / 8N2. The host (this script) generates the whole
# DMX512 frame; the M5 unit is just an isolated RS-485 transceiver.
#
# Each frame is: BREAK (1 ms low) + MAB + start code 0x00 + data slots.
# uart.break(1) holds TX low for 1 ms (>= 88 us spec minimum); the natural gap
# before write() forms the Mark After Break. If a fixture refuses to latch, the
# MAB is likely too short, add a `sleep_ms 1` between break and write.
#
# Modes (pick from the on-screen menu):
#   1  Scope    repeat a fixed, edge-rich frame for oscilloscope capture (M0).
#   2  Ramp     fade the fixture dimmer channel 0 -> 255 -> 0 (M1).
#   3  Timing   measure how long a blocking write stalls Core 0 (R5).
#   B  Blackout send all-zero slots (fixtures hold their last value on signal loss).
#   Q  Quit     blackout, then return to IRB.
#
# Edit the dmx_uart_probe(...) call at the bottom to match the fixture under
# test (dimmer channel and any channels that must be held to make light appear,
# e.g. a shutter). Fixture DMX charts are pinned down later in M3.

def dmx_uart_probe(dimmer_ch: 1, hold_channels: {}, slots: 32)
  unless defined?(UART)
    puts "UART class is missing from this build."
    puts "Enable picoruby-uart in build_config, then: rake distclean && rake"
    return
  end

  uart = UART.new(unit: :RP2040_UART1, txd_pin: 20, rxd_pin: 21,
                  baudrate: 250000, data_bits: 8, stop_bits: 2,
                  parity: UART::PARITY_NONE)
  keyboard = $keyboard

  attr_clear  = 0xF0
  attr_normal = 0xF0
  attr_title  = 0x1F
  attr_active = 0xF4

  # universe[0] is the DMX start code (always 0x00); universe[ch] holds slot ch.
  universe = Array.new(slots + 1, 0)

  # Send one DMX512 frame: 1 ms BREAK, then start code + data slots.
  send_frame = lambda do |buf|
    uart.break(1)
    uart.write(buf.pack("C*"))
  end

  # Drive every slot to 0. Fixtures freeze on signal loss, so this is the only
  # way to actually turn the rig off.
  blackout = lambda do
    zeros = Array.new(slots + 1, 0)
    8.times { send_frame.call(zeros); sleep_ms 5 }
  end

  # Esc / Ctrl-C returns from a mode loop back to the menu.
  back_key = lambda do |k|
    k && (k == Keyboard::ESCAPE || k == Keyboard::CTRL_C)
  end

  # Mode 1: repeat one fixed, recognizable frame so the scope trigger is stable.
  # Short frame, lots of edges: 0xFF / 0x00 show full swing, 0x55 / 0xAA show
  # every bit toggling for edge-quality and logic checks.
  run_scope = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Scope frame (M0): fixed pattern repeating at ~40 Hz", attr_title)
    DVI::Text.put_string(0, 2, "Trigger on the falling edge of BREAK. Expect, in order:", attr_normal)
    DVI::Text.put_string(2, 3, "BREAK 1 ms low -> MAB high -> start code 0x00 -> 8 slots", attr_normal)
    DVI::Text.put_string(2, 4, "slots: FF 00 55 AA FF 00 0F F0  (each byte 8N2, 44 us/byte)", attr_normal)
    DVI::Text.put_string(0, 6, "Check: A/B differential never floats through BREAK (R4),", attr_normal)
    DVI::Text.put_string(2, 7, "edges are clean (R3), logic is correct (R1).", attr_normal)
    DVI::Text.put_string(0, 9, "Esc: back to menu", attr_normal)
    scope = [0x00, 0xFF, 0x00, 0x55, 0xAA, 0xFF, 0x00, 0x0F, 0xF0]
    frames = 0
    loop do
      send_frame.call(scope)
      frames += 1
      if (frames % 8) == 0
        DVI::Text.put_string(0, 11, "frames sent: #{frames}      ", attr_normal)
        DVI::Text.commit
      end
      break if back_key.call(keyboard.read_char)
      sleep_ms 20
    end
  end

  # Mode 2 (M1): ramp the dimmer channel 0 -> 255 -> 0 while holding any
  # channels the fixture needs to emit light, refreshing continuously.
  run_ramp = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "Dimmer ramp (M1): fading dimmer 0 -> 255 -> 0", attr_title)
    DVI::Text.put_string(0, 2, "dimmer ch = #{dimmer_ch}   hold = #{hold_channels.inspect}   slots = #{slots}", attr_normal)
    DVI::Text.put_string(0, 3, "If the fixture stays dark, it needs more channels held", attr_normal)
    DVI::Text.put_string(2, 4, "(shutter/mode). Set hold_channels and re-run.", attr_normal)
    DVI::Text.put_string(0, 6, "Esc: back to menu (channel is left at its current value)", attr_normal)
    hold_channels.each { |ch, v| universe[ch] = v if ch >= 1 && ch <= slots }
    value = 0
    step = 3
    frames = 0
    loop do
      universe[dimmer_ch] = value
      send_frame.call(universe)
      frames += 1
      value += step
      if value >= 255
        value = 255
        step = -3
      elsif value <= 0
        value = 0
        step = 3
      end
      if (frames % 4) == 0
        bars = value / 8
        meter = ("#" * bars) + ("." * (32 - bars))
        DVI::Text.put_string(0, 8, "dimmer ch #{dimmer_ch} = #{value}    [#{meter}]   ", attr_active)
        DVI::Text.commit
      end
      break if back_key.call(keyboard.read_char)
      sleep_ms 25
    end
  end

  # Mode 3 (R5): how long does a blocking write hold Core 0?
  # 250000 baud, 8N2 = 11 bits/byte = 44 us/byte in theory.
  run_timing = lambda do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "R5: blocking-write Core 0 stall (250k 8N2 = 44 us/byte)", attr_title)
    DVI::Text.put_string(0, 2, " slots   write_us   write_ms(board_millis)", attr_normal)
    sizes = [24, 160, 512]
    row = 3
    i = 0
    while i < sizes.length
      n = sizes[i]
      buf = Array.new(n + 1, 0) # start code + n data slots
      send_frame.call(buf)      # prime the line / FIFO
      sleep_ms 5
      packed = buf.pack("C*")
      us0 = Machine.uptime_us
      ms0 = Machine.board_millis
      uart.write(packed)
      us1 = Machine.uptime_us
      ms1 = Machine.board_millis
      DVI::Text.put_string(0, row, sprintf("%6d   %8d   %8d", n, us1 - us0, ms1 - ms0), attr_active)
      row += 1
      i += 1
    end
    bus0 = Machine.uptime_us
    uart.break(1)
    bus1 = Machine.uptime_us
    DVI::Text.put_string(0, row + 1, "break(1): #{bus1 - bus0} us fixed per frame", attr_normal)
    DVI::Text.put_string(0, row + 3, "160 slots near 7 ms or 512 near 23 ms means DMA (M2) is needed.", attr_normal)
    DVI::Text.put_string(0, row + 5, "Esc: back to menu", attr_normal)
    DVI::Text.commit
    loop do
      break if back_key.call(keyboard.read_char)
      sleep_ms 30
    end
  end

  # Start from a known-dark rig.
  DVI.set_mode(DVI::TEXT_MODE)
  blackout.call

  loop do
    DVI::Text.clear(attr_clear)
    DVI::Text.put_string(0, 0, "=== DMX UART probe (M0/M1)  UART1 250k 8N2  TX=GPIO20 ===", attr_title)
    DVI::Text.put_string(0, 2, "Fixture: dimmer ch #{dimmer_ch}  hold #{hold_channels.inspect}  slots #{slots}", attr_normal)
    DVI::Text.put_string(0, 4, "Modes:", attr_normal)
    DVI::Text.put_string(2, 5, "1  Scope    repeat fixed edge-rich frame for the oscilloscope", attr_normal)
    DVI::Text.put_string(2, 6, "2  Ramp     fade dimmer ch 0 -> 255 -> 0", attr_normal)
    DVI::Text.put_string(2, 7, "3  Timing   measure blocking-write Core 0 stall", attr_normal)
    DVI::Text.put_string(2, 8, "B  Blackout set all slots to 0", attr_normal)
    DVI::Text.put_string(2, 9, "Q  Quit     blackout and return to IRB", attr_normal)
    DVI::Text.put_string(0, 11, "In a mode, press Esc to come back here.", attr_normal)
    DVI::Text.commit

    choice = nil
    loop do
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
      run_scope.call
    when "2"
      run_ramp.call
    when "3"
      run_timing.call
    when "b", "B"
      blackout.call
      DVI::Text.put_string(0, 13, "Blackout sent.", attr_active)
      DVI::Text.commit
      sleep_ms 600
    end
  end

  blackout.call
  DVI::Text.clear(attr_clear)
  DVI::Text.commit
  puts "dmx_uart_probe: done (rig blacked out)."
end

# Edit these to match the fixture on the bench. Example with a shutter held open:
#   dmx_uart_probe(dimmer_ch: 1, hold_channels: { 6 => 255 })
dmx_uart_probe(dimmer_ch: 1, hold_channels: {})
