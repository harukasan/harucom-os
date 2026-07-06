# johakyu_demo: M4 stage A verification, sound and light from one clock.
#
# Run from IRB:  run app/johakyu_demo.rb
#
# Drives the SHEHDS rig (s1/s2, 13ch, base 1/14) and the PWM tone
# voices from the same step sequencer. The M4 acceptance line is
# preset 1: the dimmer must rise exactly on each kick. Preset changes
# rebind the same track names, so they demonstrate the quantized swap
# (edits land at the next cycle boundary, never mid-step).
#
# Presets:
#   1  Kick pulse    four on the floor, both lights flash on the kick
#   2  Backbeat      kick + snare, s1/s2 alternate per beat
#   3  Hats + color  eighth hats, color steps, dimmer accents
# Keys:
#   1/2/3 preset   -/= tempo down/up   Esc/q quit
#
# The status block shows the R15 measurements: scheduler tick average
# and maximum (ms), pending events, and fired event count.

require "board/pwm_audio"
require "johakyu/dsl"

def johakyu_demo
  keyboard = $keyboard

  attr_clear  = 0xF0
  attr_normal = 0xF0
  attr_title  = 0x1F
  attr_active = 0xF4

  DMX.init
  DMX.start
  DMX.deadman_ms = 500
  patch = Johakyu.patch
  DMX.active_slots = patch.max_channel

  audio = Board::PWMAudio.new
  session = Johakyu::Session.new(audio: audio, bpm: 120)
  bpm = 120

  # Every preset binds the same track names so a preset switch swaps
  # each track at the next cycle boundary and leaves no stale tracks.
  preset_name = ""
  apply_preset = lambda do |n|
    case n
    when 1
      preset_name = "1 Kick pulse"
      session.seq(:bd, [1, 0, 0, 0, 1, 0, 0, 0])
      session.seq(:sn, [])
      session.seq(:hh, [])
      session.dmx_seq(:s1, :dimmer, [1.0, 0, 0, 0, 1.0, 0, 0, 0])
      session.dmx_seq(:s2, :dimmer, [1.0, 0, 0, 0, 1.0, 0, 0, 0])
      session.dmx_seq(:s1, :color, [:white])
      session.dmx_seq(:s2, :color, [:white])
    when 2
      preset_name = "2 Backbeat"
      session.seq(:bd, [1, 0, 0, 0, 1, 0, 0, 0])
      session.seq(:sn, [0, 0, 1, 0, 0, 0, 1, 0])
      session.seq(:hh, [])
      session.dmx_seq(:s1, :dimmer, [1.0, 0, 0, 0, 1.0, 0, 0, 0])
      session.dmx_seq(:s2, :dimmer, [0, 0, 1.0, 0, 0, 0, 1.0, 0])
      session.dmx_seq(:s1, :color, [:white])
      session.dmx_seq(:s2, :color, [:blue])
    when 3
      preset_name = "3 Hats + color"
      session.seq(:bd, [1, 0, 0, 0, 1, 0, 0, 0])
      session.seq(:sn, [0, 0, 1, 0, 0, 0, 1, 0])
      session.seq(:hh, [0.6, 0.3, 0.6, 0.3, 0.6, 0.3, 0.6, 0.3])
      session.dmx_seq(:s1, :dimmer, [1.0, 0.2, 0.5, 0.2, 1.0, 0.2, 0.5, 0.2])
      session.dmx_seq(:s2, :dimmer, [1.0, 0.2, 0.5, 0.2, 1.0, 0.2, 0.5, 0.2])
      session.dmx_seq(:s1, :color, [:red, :blue, :yellow, :green])
      session.dmx_seq(:s2, :color, [:blue, :red, :green, :yellow])
    end
  end
  apply_preset.call(1)

  DVI::Text.clear(attr_clear)
  DVI::Text.put_string(0, 0, "=== Johakyu demo (M4 stage A)  sound + light on one clock ===", attr_title)
  DVI::Text.put_string(0, 2, "1/2/3: preset (swaps at next cycle)   -/=: tempo   [/]: audio latency   Esc/q: quit", attr_normal)

  scheduler = session.scheduler
  running = true
  frame = 0
  while running
    session.update
    DMX.keepalive

    # Redraw at roughly 20 Hz. Drawing every iteration makes the loop
    # longer, which delays event firing and starves the audio buffer.
    frame += 1
    if frame % 5 == 0
      position = session.clock.position
      position_int = position.to_i
      position_frac = ((position - position_int) * 100).to_i
      frac_text = position_frac < 10 ? "0#{position_frac}" : "#{position_frac}"
      tick_avg_us = (scheduler.tick_ms_average * 1000).to_i
      DVI::Text.put_string(0, 4, "preset: #{preset_name}     bpm: #{bpm}     audio lat: #{session.audio_latency_ms} ms      ", attr_active)
      DVI::Text.put_string(0, 6, "cycle: #{position_int}.#{frac_text}    frames: #{DMX.frame_count}      ", attr_normal)
      DVI::Text.put_string(0, 8, "tick avg: #{tick_avg_us} us   max: #{scheduler.tick_ms_max} ms   ticks: #{scheduler.tick_count}      ", attr_normal)
      DVI::Text.put_string(0, 9, "fired: #{scheduler.fired_count}   pending: #{scheduler.pending_count}   late max: #{scheduler.fire_delay_ms_max} ms      ", attr_normal)
      DVI::Text.put_string(0, 11, "dimmer ch6: #{DMX.get(6)}   ch19: #{DMX.get(19)}      ", attr_normal)
      step = ((position - position_int) * 8).to_i
      step = 7 if step > 7
      bar = ""
      cell = 0
      while cell < 8
        bar = bar + (cell == step ? "#" : ".")
        cell += 1
      end
      DVI::Text.put_string(0, 13, "step: [#{bar}]  kick = 0/4, snare = 2/6", attr_normal)
      DVI::Text.commit
    end

    k = keyboard.read_char
    if k
      if k == Keyboard::ESCAPE || k == Keyboard::CTRL_C
        running = false
      elsif k.char
        case k.char
        when "1" then apply_preset.call(1)
        when "2" then apply_preset.call(2)
        when "3" then apply_preset.call(3)
        when "-"
          bpm = bpm > 40 ? bpm - 10 : bpm
          session.tempo(bpm)
        when "="
          bpm = bpm < 300 ? bpm + 10 : bpm
          session.tempo(bpm)
        when "["
          session.audio_latency_ms = session.audio_latency_ms - 5
        when "]"
          latency = session.audio_latency_ms + 5
          session.audio_latency_ms = latency > 150 ? 150 : latency
        when "q", "Q"
          running = false
        end
      end
    end
    sleep_ms 10
  end

  session.stop_sounds
  audio.deinit
  DMX.blackout
  8.times do
    DMX.keepalive
    sleep_ms 25
  end
  DMX.stop
  DVI::Text.clear(attr_clear)
  DVI::Text.commit
  puts "johakyu_demo: done (engine stopped)."
end

johakyu_demo
