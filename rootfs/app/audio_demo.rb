# audio_demo: Board::PWMAudio waveform synthesizer demo
#
# Hold keyboard keys to play notes. Up to 3 keys for chords.
# Sound stops when keys are released.
# Press Ctrl-C or Escape to quit.

require "board/pad"
require "board/pwm_audio"

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
DVI::Text.put_string(0, 6, "Pad UP/DOWN: octave  Esc: quit", 0xF0)

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

octave = 4
waveform = Board::PWMAudio::SQUARE
waveform_idx = 1
prev_octave_up = false
prev_octave_down = false
prev_note_keycodes = []

loop do
  # Consume key events for Ctrl-C detection
  key = keyboard.read_char
  if key == Keyboard::CTRL_C || key == Keyboard::ESCAPE
    audio.deinit
    DVI::Text.clear(0xF0)
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

  # Collect currently held note keycodes (up to 3)
  note_keycodes = []
  keycodes.each do |kc|
    if NOTE_KEYCODES[kc] && note_keycodes.length < 3
      note_keycodes << kc
    end
  end

  # Update channels only when held notes change
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
  end

  # Status display
  DVI::Text.put_string(0, 8, "Octave: #{octave}  Waveform: #{WAVEFORM_NAMES[waveform_idx]}       ", LABEL_ATTR)

  audio.update
  DVI::Text.commit
end
