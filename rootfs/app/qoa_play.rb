# qoa_play: stream a QOA file from raw flash without johakyu
#
# Isolation test for the lumica show. Talks to PWMAudio directly, so a
# failure here points at the C stream layer or the flash content, not
# the pattern engine. Each step prints before it runs, so the last
# visible line names the step that hangs. Ctrl-C stops playback.
#
# Usage from IRB:
#   qoa_play

require "board/pwm_audio"

SONG_ADDRESS = 0x10440000
SONG_BYTES = 1826184
SONG_CHANNEL = 6
SONG_VOLUME = 14

# Pack a u32 little-endian into the extent string.
def append_u32(string, value)
  i = 0
  while i < 4
    string << ((value >> (i * 8)) & 0xFF).chr
    i += 1
  end
end

extents = ""
append_u32(extents, SONG_ADDRESS)
append_u32(extents, SONG_BYTES)

puts "QOA stream test: 0x#{SONG_ADDRESS.to_s(16)}, #{SONG_BYTES} bytes"

puts "step 1: init audio"
audio = Board::PWMAudio.new

puts "step 2: stream_info (header probe, no playback)"
info = nil
begin
  info = ::PWMAudio.stream_info(extents, SONG_BYTES)
rescue ArgumentError => e
  puts "  FAILED: #{e.message}"
  puts "  the flash region does not start with a QOA/WAV header."
  puts "  was the song part of the flashed UF2?"
  return
end
samplerate = info[0]
frames = info[1]
channels = info[2]
duration = frames / samplerate
puts "  #{samplerate} Hz, #{channels} ch, #{frames} frames, #{duration} s"

puts "step 3: set_stream"
audio.set_stream(SONG_CHANNEL, extents, SONG_BYTES)

puts "step 4: play"
::PWMAudio.play(SONG_CHANNEL, SONG_VOLUME)

puts "playing (Ctrl-C to stop)"
begin
  start = audio.sample_clock
  elapsed = 0
  tick = 0
  while elapsed < duration + 2
    sleep_ms 1000
    tick += 1
    elapsed = (audio.sample_clock - start) / ::PWMAudio::SAMPLE_RATE
    puts "  t=#{elapsed}s / #{duration}s" if tick % 5 == 0
  end
  puts "done"
ensure
  audio.stop(SONG_CHANNEL)
end
