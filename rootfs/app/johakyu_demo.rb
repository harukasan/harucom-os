# johakyu_demo: all-pattern DSL verification, sound and light from
# one clock.
#
# Run from IRB:  run app/johakyu_demo.rb
#
# Drives the SHEHDS rig (s1/s2, 13ch, base 1/14) and the drum kit
# sampler from one scheduler. Every preset binds the same track names,
# so switching demonstrates the quantized swap (edits land at the next
# cycle boundary, never mid-step). Preset 4 is the all-pattern
# acceptance line: light controls attached to the sound events ride
# the beat from a single statement.
#
# Presets:
#   1  Kick pulse    four on the floor, both lights flash on the kick
#   2  Backbeat      kick + snare, s1/s2 alternate per beat
#   3  Hats + color  eighth hats, color steps, dimmer accents
#   4  Sound+light   color and dimmer attached to the drum events
#   5  Transforms    every/fast/euclid + segmented signals
# Keys:
#   1-5 preset   -/= tempo down/up   [/] audio latency trim   Esc/q quit
#
# The status block shows the R15 measurements: scheduler tick average
# and maximum (ms), pending events, and fired event count. Use them as
# the B4 gate numbers on the board.

require "board/pwm_audio"
require "johakyu/live"

# The rig is patched through the live layer like any script: two
# SHEHDS units from the shipped OFL definition, group :all. Presets
# that follow leave the patch alone (no fixture statements).
def patch_rig(live)
  live.begin_recording
  fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
  fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
  group :all, :s1, :s2
  live.apply
end

# Presets record through the live layer, so they read exactly like
# an editor buffer (top-level DSL, no receiver) and stale tracks
# disappear through the replace semantics. Returns the preset name.
def apply_preset(session, live, n)
  # Stats restart per preset so tick/late/stage read as steady-state
  # numbers for this preset (the swap transient is still included).
  session.reset_stats
  live.begin_recording
  name = ""
  case n
  when 1
    name = "1 Kick pulse"
    track(:drums)  { sound("bd ~ ~ ~ bd ~ ~ ~") }
    track(:light1) { dimmer("1 0 0 0 1 0 0 0").color("white").on(:all) }
    track(:light2) { pan(0.5).on(:s2) }
  when 2
    name = "2 Backbeat"
    track(:drums)  { sound("bd ~ sd ~ bd ~ sd ~") }
    track(:light1) { dmx(:s1).dimmer("1 0 0 0 1 0 0 0").color("white") }
    track(:light2) { dmx(:s2).dimmer("0 0 1 0 0 0 1 0").color("blue") }
  when 3
    name = "3 Hats + color"
    track(:drums)  { sound("bd ~ sd ~, hh*8") }
    track(:light1) { dmx(:s1).dimmer("1 0.2 0.5 0.2").color("<red blue yellow green>") }
    track(:light2) { dmx(:s2).dimmer("1 0.2 0.5 0.2").color("<blue red green yellow>") }
  when 4
    name = "4 Sound+light (all-pattern)"
    # One statement: the lights ride the drum events themselves.
    track(:drums)  { sound("bd ~ [sd sd] ~, hh*8").dimmer(1.0).color("<red blue yellow>").on(:all) }
    track(:light2) { pan("0.5").on(:s2) }
  when 5
    name = "5 Transforms"
    track(:drums) do
      stack(
        sound("bd ~ bd ~"),
        sound("sd").euclid(3, 8),
        sound("hh*8")
      ).every(4) { |p| p.fast(2) }
    end
    track(:light1) { dmx(:s1).dimmer(saw.segment(8).slow(2)).color("<red blue yellow>") }
    track(:light2) { dmx(:s2).pan(sine.range(0.3, 0.7).slow(8)) }
  end
  live.apply
  name
end

def johakyu_demo
  keyboard = $keyboard

  attr_clear  = 0xF0
  attr_normal = 0xF0
  attr_title  = 0x1F
  attr_active = 0xF4

  DMX.init
  DMX.start
  DMX.deadman_ms = 500

  audio = Board::PWMAudio.new
  session = Johakyu::Session.new(audio: audio, bpm: 120)
  session.load_kit
  live = Johakyu::Live.new(session)
  $johakyu_live = live
  patch_rig(live)
  bpm = 120

  preset_name = apply_preset(session, live, 1)

  DVI::Text.clear(attr_clear)
  DVI::Text.put_string(0, 0, "=== Johakyu demo  sound + light on one clock ===", attr_title)
  DVI::Text.put_string(0, 2, "1-5: preset (swaps at next cycle)   -/=: tempo   [/]: latency   Esc/q: quit", attr_normal)

  scheduler = session.scheduler
  running = true
  frame = 0

  # Prebuilt step cursor rows so the per-iteration redraw allocates
  # nothing.
  step_rows = []
  s = 0
  while s < 8
    bar = ""
    cell = 0
    while cell < 8
      bar = bar + (cell == s ? "#" : ".")
      cell += 1
    end
    step_rows << "step: [#{bar}]"
    s += 1
  end

  while running
    session.update
    DMX.keepalive

    position = session.clock.position
    position_int = position.to_i

    # Full status redraw at roughly 20 Hz. Building all the strings
    # every iteration would lengthen the loop and delay event firing.
    frame += 1
    if frame % 5 == 0
      position_frac = ((position - position_int) * 100).to_i
      frac_text = position_frac < 10 ? "0#{position_frac}" : "#{position_frac}"
      tick_avg_us = (scheduler.tick_ms_average * 1000).to_i
      DVI::Text.put_string(0, 4, "preset: #{preset_name}     bpm: #{bpm}     latency trim: #{session.audio_latency_ms} ms      ", attr_active)
      DVI::Text.put_string(0, 6, "cycle: #{position_int}.#{frac_text}    frames: #{DMX.frame_count}      ", attr_normal)
      DVI::Text.put_string(0, 8, "tick avg: #{tick_avg_us} us   max: #{scheduler.tick_ms_max} ms   stage max: #{scheduler.stage_ms_max} ms      ", attr_normal)
      DVI::Text.put_string(0, 9, "fired: #{scheduler.fired_count}   pending: #{scheduler.pending_count}   late max: #{scheduler.fire_delay_ms_max} ms      ", attr_normal)
      DVI::Text.put_string(0, 10, "out late: #{session.output_late_count} (max #{session.output_late_ms_max} ms, lead #{Johakyu::Session::RESERVE_LEAD_MS} ms)      ", attr_normal)
      DVI::Text.put_string(0, 11, "dimmer ch6: #{DMX.get(6)}   ch19: #{DMX.get(19)}      ", attr_normal)
    end

    step = ((position - position_int) * 8).to_i
    step = 7 if step > 7
    DVI::Text.put_string(0, 13, step_rows[step], attr_normal)
    DVI::Text.commit

    k = keyboard.read_char
    if k
      if k == Keyboard::ESCAPE || k == Keyboard::CTRL_C
        running = false
      elsif k.char
        case k.char
        when "1" then preset_name = apply_preset(session, live, 1)
        when "2" then preset_name = apply_preset(session, live, 2)
        when "3" then preset_name = apply_preset(session, live, 3)
        when "4" then preset_name = apply_preset(session, live, 4)
        when "5" then preset_name = apply_preset(session, live, 5)
        when "-"
          bpm = bpm > 40 ? bpm - 10 : bpm
          session.tempo(bpm)
        when "="
          bpm = bpm < 300 ? bpm + 10 : bpm
          session.tempo(bpm)
        when "["
          trim = session.audio_latency_ms - 5
          session.audio_latency_ms = trim < -50 ? -50 : trim
        when "]"
          trim = session.audio_latency_ms + 5
          session.audio_latency_ms = trim > 150 ? 150 : trim
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
