# audio_demo: Board::PWMAudio synthesizer and drum kit demo
#
# Hold keyboard keys to play notes. Up to 3 keys for chords; sound
# stops when keys are released. The bottom row triggers drum
# one-shots on channels 3-7 (open and closed hihat share a channel,
# so they choke each other like a real hihat).
# Press Ctrl-C or Escape to quit.

require "board/pad"
require "board/pwm_audio"
require "synth/drum_kit"

keyboard = $keyboard
audio = Board::PWMAudio.new
left_pad = Board::Pad.new(Board::PAD0_PIN)

DVI.set_mode(DVI::TEXT_MODE)
DVI::Text.clear(0xF0)
DVI::Text.put_string(0, 0, "Board::PWMAudio Demo", 0x1F)
DVI::Text.put_string(0, 2, "Hold keys to play (up to 3 notes):", 0xF0)
DVI::Text.put_string(0, 3, "  A S D F G H J = C D E F G A B", 0xF0)
DVI::Text.put_string(0, 4, "  W E   T Y U   = C# D#  F# G# A#", 0xF0)
DVI::Text.put_string(0, 5, "1:Sine 2:Square 3:Triangle 4:Sawtooth", 0xF0)
DVI::Text.put_string(0, 6, "Drums: Z X C V B N M , = bd sd hh oh cp lt ht rim", 0xF0)
DVI::Text.put_string(0, 7, "Pad UP/DOWN: octave  Esc: quit", 0xF0)

LABEL_ATTR = 0xF0
NOTE_ATTR  = 0xF4

# HID keycode -> semitone (0-11)
# HID keycodes: a=0x04, b=0x05, ..., z=0x1D
NOTE_KEYCODES = {
  0x04 => 0,   # A -> C
  0x1A => 1,   # W -> C#
  0x16 => 2,   # S -> D
  0x08 => 3,   # E -> D#
  0x07 => 4,   # D -> E
  0x09 => 5,   # F -> F
  0x17 => 6,   # T -> F#
  0x0A => 7,   # G -> G
  0x1C => 8,   # Y -> G#
  0x0B => 9,   # H -> A
  0x18 => 10,  # U -> A#
  0x0D => 11,  # J -> B
}

# HID keycodes for waveform selection (1-4 keys)
KC_1 = 0x1E; KC_2 = 0x1F; KC_3 = 0x20; KC_4 = 0x21
# HID keycodes for quit
KC_ESCAPE = 0x29

# HID keycode -> drum name (bottom row)
DRUM_KEYCODES = {
  0x1D => "bd",  # Z
  0x1B => "sd",  # X
  0x06 => "hh",  # C
  0x19 => "oh",  # V
  0x05 => "cp",  # B
  0x11 => "lt",  # N
  0x10 => "ht",  # M
  0x36 => "rim", # ,
}

# Drum channel map: tones use channels 0-2, drums 3-7. Pairs sharing
# a channel cut each other off (hh/oh is the hihat choke).
DRUM_CHANNELS = {
  "bd" => 3, "sd" => 4, "hh" => 5, "oh" => 5,
  "cp" => 6, "rim" => 6, "lt" => 7, "ht" => 7,
}
DRUM_VOLUME = 14

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
WAVEFORM_NAMES = ["Sine", "Square", "Triangle", "Sawtooth"]

def note_frequency(semitone, octave)
  base = [262, 277, 294, 311, 330, 349, 370, 392, 415, 440, 466, 494]
  freq = base[semitone]
  shift = octave - 4
  if shift > 0
    shift.times { freq = freq * 2 }
  elsif shift < 0
    (-shift).times { freq = freq / 2 }
  end
  freq
end

# Load the kit from /data/drums; a missing file falls back to
# rendering the same definition on the board.
drum_samples = {}
DRUM_KEYCODES.each_value do |name|
  data = nil
  begin
    data = File.open("/data/drums/#{name}.wav", "r") { |f| f.read }
  rescue
    data = Synth::DrumKit.render(name)
  end
  drum_samples[name] = PWMAudio::Sample.new(data)
end

octave = 4
waveform = Board::PWMAudio::SQUARE
waveform_idx = 1
prev_octave_up = false
prev_octave_down = false
prev_note_keycodes = []
prev_keycodes = []
prev_status = nil

loop do
  # Consume key events for Ctrl-C detection
  key = keyboard.read_char
  if key == Keyboard::CTRL_C || key == Keyboard::ESCAPE
    audio.deinit
    DVI::Text.clear(0xF0)
    DVI::Text.commit
    return
  end

  # Octave shift via pad (edge detection)
  left_pad.read
  if left_pad.up? && !prev_octave_up
    octave = octave + 1 if octave < 7
  end
  if left_pad.down? && !prev_octave_down
    octave = octave - 1 if octave > 1
  end
  prev_octave_up = left_pad.up?
  prev_octave_down = left_pad.down?

  # Read currently held keys directly from HID report
  keycodes = USB::Host.keyboard_keycodes

  # Waveform selection (edge detection via key events)
  if key
    case key.char
    when "1"
      waveform = Board::PWMAudio::SINE
      waveform_idx = 0
    when "2"
      waveform = Board::PWMAudio::SQUARE
      waveform_idx = 1
    when "3"
      waveform = Board::PWMAudio::TRIANGLE
      waveform_idx = 2
    when "4"
      waveform = Board::PWMAudio::SAWTOOTH
      waveform_idx = 3
    end
  end

  # Trigger drums on newly pressed keys (edge detection on the raw
  # report, so holding a key does not machine-gun the drum)
  keycodes.each do |kc|
    next if prev_keycodes.include?(kc)
    name = DRUM_KEYCODES[kc]
    next unless name
    channel = audio.channel(DRUM_CHANNELS[name])
    channel.source = drum_samples[name]
    channel.play(volume: DRUM_VOLUME)
  end
  prev_keycodes = keycodes

  # Collect currently held note keycodes (up to 3)
  note_keycodes = []
  keycodes.each do |kc|
    if NOTE_KEYCODES[kc] && note_keycodes.length < 3
      note_keycodes << kc
    end
  end

  # Update channels only when held notes change
  dirty = false
  if note_keycodes != prev_note_keycodes
    # Scale volume by number of simultaneous notes to avoid clipping
    count = note_keycodes.length
    volume = if count <= 1 then 15
             elsif count == 2 then 12
             else 10
             end

    # Assign held notes to channels 0-2
    3.times do |ch|
      kc = note_keycodes[ch]
      if kc
        semitone = NOTE_KEYCODES[kc]
        freq = note_frequency(semitone, octave)
        audio.tone(ch, freq, waveform: waveform, volume: volume)
      else
        audio.stop(ch)
      end
    end

    # Display
    if note_keycodes.length > 0
      names = note_keycodes.map { |kc| "#{NOTE_NAMES[NOTE_KEYCODES[kc]]}#{octave}" }
      DVI::Text.put_string(0, 10, "Playing: #{names.join(" + ")}                    ", NOTE_ATTR)
    else
      DVI::Text.put_string(0, 10, "                                        ", LABEL_ATTR)
    end

    prev_note_keycodes = note_keycodes
    dirty = true
  end

  # Status display
  status = "Octave: #{octave}  Waveform: #{WAVEFORM_NAMES[waveform_idx]}       "
  if status != prev_status
    DVI::Text.put_string(0, 8, status, LABEL_ATTR)
    prev_status = status
    dirty = true
  end

  # Commit blocks until vsync, so only pay for it when the display
  # changed. Idle iterations sleep briefly instead, which samples the
  # key state at millisecond granularity and lets the USB host task
  # run, cutting key-to-sound latency. Sound is already triggered
  # above, so a commit never delays it.
  if dirty
    DVI::Text.commit
  else
    sleep_ms 1
  end
end
