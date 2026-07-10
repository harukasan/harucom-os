# audio_demo: Board::PWMAudio synthesizer and drum kit demo
#
# The screen mirrors the physical keyboard: the top rows are the piano
# keys (black keys on the number-adjacent row, white keys on the home
# row) and the bottom row is the drum pads. Held keys light up. Hold up
# to 3 note keys for chords; sound stops when keys are released. Drums
# are one-shots on channels 3-7 (open and closed hihat share a channel,
# so they choke each other like a real hihat).

require "board/pad"
require "board/pwm_audio"
require "synth/drum_kit"

keyboard = $keyboard
audio = Board::PWMAudio.new
left_pad = Board::Pad.new(Board::PAD0_PIN)

TEXT_ATTR    = 0xF0
BAR_ATTR     = 0x0F
PLAYING_ATTR = 0xF4

# HID keycode -> semitone above the base octave's C. The row keeps
# going past the octave (12-16) like a DAW keyboard, so K L ; play
# C D E of the next octave with O and P as their black keys.
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
  0x0E => 12,  # K -> C (next octave)
  0x12 => 13,  # O -> C#
  0x0F => 14,  # L -> D
  0x13 => 15,  # P -> D#
  0x33 => 16,  # ; -> E
}

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

# Screen layout, staggered like the physical key rows: white keys on
# the home row, black keys in the gaps above them, drums half a key to
# the right below. One cell per key: "[A]" plus a label underneath.
WHITE_KEYS = [["A", 0x04], ["S", 0x16], ["D", 0x07], ["F", 0x09],
              ["G", 0x0A], ["H", 0x0B], ["J", 0x0D], ["K", 0x0E],
              ["L", 0x0F], [";", 0x33]]
BLACK_KEYS = [["W", 0x1A, 0], ["E", 0x08, 1], ["T", 0x17, 3],
              ["Y", 0x1C, 4], ["U", 0x18, 5], ["O", 0x12, 7],
              ["P", 0x13, 8]]
DRUM_KEYS = [["Z", 0x1D], ["X", 0x1B], ["C", 0x06], ["V", 0x19],
             ["B", 0x05], ["N", 0x11], ["M", 0x10], [",", 0x36]]

BLACK_CAP_ROW = 2
BLACK_LABEL_ROW = 3
WHITE_CAP_ROW = 5
WHITE_LABEL_ROW = 6
DRUM_CAP_ROW = 8
DRUM_LABEL_ROW = 9
PLAYING_ROW = 11

cols = DVI::Text.cols
rows = DVI::Text.rows
command_row = rows - 1
# Ten white keys at width 6 need 60 columns; the zoomed 53-column grid
# gets width 5.
key_width = cols >= WHITE_KEYS.length * 6 + 4 ? 6 : 5
left = (cols - WHITE_KEYS.length * key_width) / 2
left = 1 if left < 1

# keycode -> [column, row] of its cap on screen
key_cells = {}
i = 0
while i < WHITE_KEYS.length
  key_cells[WHITE_KEYS[i][1]] = [left + i * key_width, WHITE_CAP_ROW]
  i += 1
end
i = 0
while i < BLACK_KEYS.length
  gap = BLACK_KEYS[i][2]
  key_cells[BLACK_KEYS[i][1]] = [left + gap * key_width + key_width / 2, BLACK_CAP_ROW]
  i += 1
end
i = 0
while i < DRUM_KEYS.length
  key_cells[DRUM_KEYS[i][1]] = [left + 2 + i * key_width, DRUM_CAP_ROW]
  i += 1
end

def note_frequency(semitone, octave)
  base = [262, 277, 294, 311, 330, 349, 370, 392, 415, 440, 466, 494]
  freq = base[semitone % 12].to_f
  shift = octave + semitone / 12 - 4
  if shift > 0
    shift.times { freq = freq * 2 }
  elsif shift < 0
    (-shift).times { freq = freq / 2 }
  end
  freq.round
end

def note_name(semitone, octave)
  "#{NOTE_NAMES[semitone % 12]}#{octave + semitone / 12}"
end

# Load the kit from /data/drums; a missing or unreadable file falls
# back to rendering the same definition on the board. Note that
# File.open of a missing file returns nil instead of raising.
drum_samples = {}
DRUM_KEYCODES.each_value do |name|
  data = nil
  begin
    data = File.open("/data/drums/#{name}.wav", "r") { |f| f.read }
  rescue
    data = nil
  end
  if data.nil? || data.bytesize < 44
    started = Machine.uptime_us
    data = Synth::DrumKit.render(name)
    # STDOUT is the debug UART; keep the render timing off the screen.
    STDOUT.puts "audio_demo: rendered #{name} on board in #{(Machine.uptime_us - started) / 1000} ms"
  end
  drum_samples[name] = PWMAudio::Sample.new(data)
end

octave = 4
transpose = 0
waveform = Board::PWMAudio::SQUARE
waveform_idx = 1

draw_title = lambda do
  title = " audio demo  octave #{octave}  transpose #{sprintf("%+d", transpose)}  #{WAVEFORM_NAMES[waveform_idx].downcase}"
  DVI::Text.put_string(0, 0, title.ljust(cols)[0, cols], BAR_ATTR)
end

draw_cap = lambda do |keycode, held|
  cell = key_cells[keycode]
  cap = nil
  WHITE_KEYS.each { |k| cap = k[0] if k[1] == keycode }
  BLACK_KEYS.each { |k| cap = k[0] if k[1] == keycode } unless cap
  DRUM_KEYS.each { |k| cap = k[0] if k[1] == keycode } unless cap
  DVI::Text.put_string(cell[0], cell[1], "[#{cap}]", held ? BAR_ATTR : TEXT_ATTR)
end

draw_keyboard = lambda do
  i2 = 0
  while i2 < BLACK_KEYS.length
    keycode = BLACK_KEYS[i2][1]
    x = key_cells[keycode][0]
    draw_cap.call(keycode, false)
    DVI::Text.put_string(x, BLACK_LABEL_ROW,
                         NOTE_NAMES[(NOTE_KEYCODES[keycode] + transpose) % 12].rjust(2), TEXT_ATTR)
    i2 += 1
  end
  i2 = 0
  while i2 < WHITE_KEYS.length
    keycode = WHITE_KEYS[i2][1]
    x = key_cells[keycode][0]
    draw_cap.call(keycode, false)
    DVI::Text.put_string(x + 1, WHITE_LABEL_ROW,
                         NOTE_NAMES[(NOTE_KEYCODES[keycode] + transpose) % 12].ljust(2), TEXT_ATTR)
    i2 += 1
  end
  i2 = 0
  while i2 < DRUM_KEYS.length
    keycode = DRUM_KEYS[i2][1]
    x = key_cells[keycode][0]
    draw_cap.call(keycode, false)
    DVI::Text.put_string(x, DRUM_LABEL_ROW, DRUM_KEYCODES[keycode].rjust(3), TEXT_ATTR)
    i2 += 1
  end
end

DVI.set_mode(DVI::TEXT_MODE)
DVI::Text.clear(TEXT_ATTR)
draw_title.call
draw_keyboard.call
help = " 1-4 wave   ^v octave   <> transpose   Esc quit"
DVI::Text.put_string(0, command_row, help.ljust(cols)[0, cols], BAR_ATTR)
DVI::Text.commit

prev_octave_up = false
prev_octave_down = false
prev_note_keycodes = []
prev_keycodes = []

loop do
  dirty = false

  # Consume key events for Ctrl-C detection. Leave through break: a
  # top-level return from a loaded script does not unwind reliably in
  # the IRB sandbox, so the cleanup runs at the end of the file.
  key = keyboard.read_char
  break if key == Keyboard::CTRL_C || key == Keyboard::ESCAPE

  # The idle loop runs at about 1 kHz, so it must not allocate: the
  # setting change detection compares plain Integers.
  octave_before = octave
  transpose_before = transpose
  waveform_before = waveform

  # Octave shift via pad (edge detection) or cursor keys; left/right
  # transposes in semitones.
  left_pad.read
  if left_pad.up? && !prev_octave_up
    octave = octave + 1 if octave < 7
  end
  if left_pad.down? && !prev_octave_down
    octave = octave - 1 if octave > 1
  end
  prev_octave_up = left_pad.up?
  prev_octave_down = left_pad.down?
  if key
    if key.match?(:up)
      octave = octave + 1 if octave < 7
    elsif key.match?(:down)
      octave = octave - 1 if octave > 1
    elsif key.match?(:left)
      transpose = transpose - 1 if transpose > -11
    elsif key.match?(:right)
      transpose = transpose + 1 if transpose < 11
    end
  end

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

  # Retune held notes and refresh the title right away when a setting
  # changes; a transpose move also relabels the keys with the notes
  # they now play.
  if octave != octave_before || transpose != transpose_before ||
     waveform != waveform_before
    prev_note_keycodes = nil
    draw_title.call
    dirty = true
    if transpose != transpose_before
      draw_keyboard.call
      keycodes.each { |kc| draw_cap.call(kc, true) if key_cells[kc] }
    end
  end

  if keycodes != prev_keycodes
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

    # Light the caps of keys whose held state changed.
    (keycodes + prev_keycodes).each do |kc|
      next unless key_cells[kc]
      held = keycodes.include?(kc)
      if held != prev_keycodes.include?(kc)
        draw_cap.call(kc, held)
        dirty = true
      end
    end
    prev_keycodes = keycodes
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
        semitone = NOTE_KEYCODES[kc] + transpose
        freq = note_frequency(semitone, octave)
        audio.tone(ch, freq, waveform: waveform, volume: volume)
      else
        audio.stop(ch)
      end
    end

    if note_keycodes.length > 0
      names = note_keycodes.map { |kc| note_name(NOTE_KEYCODES[kc] + transpose, octave) }
      DVI::Text.put_string(0, PLAYING_ROW, " playing: #{names.join(" + ")}".ljust(cols)[0, cols], PLAYING_ATTR)
    else
      DVI::Text.clear_line(PLAYING_ROW, TEXT_ATTR)
    end

    prev_note_keycodes = note_keycodes
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

audio.deinit
DVI::Text.clear(TEXT_ATTR)
DVI::Text.commit
