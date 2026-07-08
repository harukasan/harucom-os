#!/usr/bin/env ruby
# Convert a WAV file to QOA (https://qoaformat.org) for the board's
# sample playback (see doc/pwm-audio.md).
#
# Accepts 16-bit PCM WAV, mono or stereo. The channel count is kept;
# --mono downmixes stereo input to halve the output size. The encoder
# follows the QOA reference implementation: 20-sample slices with a
# brute-force scalefactor search, LMS state serialized per channel per
# frame, slices interleaved by channel.
#
# Usage: ruby scripts/wav2qoa.rb input.wav [-o output.qoa] [--mono] [--verify]
#
# --verify decodes the result back and reports the PSNR against the
# input, as an end-to-end check of the encoder.

QOA_SLICE_LEN = 20
QOA_SLICES_PER_FRAME = 256
QOA_FRAME_LEN = QOA_SLICE_LEN * QOA_SLICES_PER_FRAME

QOA_QUANT_TAB = [
  7, 7, 7, 5, 5, 3, 3, 1, # -8..-1
  0,                      #  0
  0, 2, 2, 4, 4, 6, 6, 6, #  1..8
].freeze

QOA_SCALEFACTOR_TAB = [
  1, 7, 21, 45, 84, 138, 211, 304, 421, 562, 731, 928, 1157, 1419, 1715, 2048
].freeze

QOA_RECIPROCAL_TAB = [
  65536, 9363, 3121, 1457, 781, 475, 311, 216, 156, 117, 90, 71, 57, 47, 39, 32
].freeze

QOA_DEQUANT_TAB = [
  [1, -1, 3, -3, 5, -5, 7, -7],
  [5, -5, 18, -18, 32, -32, 49, -49],
  [16, -16, 53, -53, 95, -95, 147, -147],
  [34, -34, 113, -113, 203, -203, 315, -315],
  [63, -63, 210, -210, 378, -378, 588, -588],
  [104, -104, 345, -345, 621, -621, 966, -966],
  [158, -158, 528, -528, 950, -950, 1477, -1477],
  [228, -228, 760, -760, 1368, -1368, 2128, -2128],
  [316, -316, 1053, -1053, 1895, -1895, 2947, -2947],
  [422, -422, 1405, -1405, 2529, -2529, 3934, -3934],
  [548, -548, 1828, -1828, 3290, -3290, 5117, -5117],
  [696, -696, 2320, -2320, 4176, -4176, 6496, -6496],
  [868, -868, 2893, -2893, 5207, -5207, 8099, -8099],
  [1064, -1064, 3548, -3548, 6386, -6386, 9933, -9933],
  [1286, -1286, 4288, -4288, 7718, -7718, 12005, -12005],
  [1536, -1536, 5120, -5120, 9216, -9216, 14336, -14336],
].freeze

# Rounding division that avoids rounding to zero, from the reference
# implementation.
def qoa_div(v, scalefactor)
  reciprocal = QOA_RECIPROCAL_TAB[scalefactor]
  n = (v * reciprocal + (1 << 15)) >> 16
  n + ((v > 0 ? 1 : 0) - (v < 0 ? 1 : 0)) - ((n > 0 ? 1 : 0) - (n < 0 ? 1 : 0))
end

def clamp(v, min, max)
  v < min ? min : (v > max ? max : v)
end

class Lms
  attr_accessor :history, :weights

  def initialize
    @history = [0, 0, 0, 0]
    @weights = [0, 0, -(1 << 13), 1 << 14]
  end

  def initialize_copy(other)
    @history = other.history.dup
    @weights = other.weights.dup
  end

  def predict
    (@weights[0] * @history[0] + @weights[1] * @history[1] +
     @weights[2] * @history[2] + @weights[3] * @history[3]) >> 13
  end

  def update(sample, residual)
    delta = residual >> 4
    4.times do |i|
      @weights[i] += @history[i] < 0 ? -delta : delta
    end
    @history[0] = @history[1]
    @history[1] = @history[2]
    @history[2] = @history[3]
    @history[3] = sample
  end
end

# Parse a 16-bit PCM WAV and return [per_channel_sample_arrays, samplerate].
def read_wav(path, force_mono: false)
  data = File.binread(path)
  raise "not a RIFF/WAVE file" unless data[0, 4] == "RIFF" && data[8, 4] == "WAVE"

  channels = nil
  samplerate = nil
  bits = nil
  pcm = nil
  pos = 12
  while pos + 8 <= data.bytesize
    chunk_id = data[pos, 4]
    chunk_size = data[pos + 4, 4].unpack1("V")
    body = data[pos + 8, chunk_size]
    case chunk_id
    when "fmt "
      format, channels, samplerate, _byte_rate, _align, bits = body.unpack("vvVVvv")
      unless format == 1 || format == 0xFFFE
        raise "unsupported WAV format #{format} (16-bit PCM only)"
      end
    when "data"
      pcm = body
    end
    pos += 8 + chunk_size + (chunk_size & 1)
  end
  raise "missing fmt or data chunk" unless channels && pcm
  raise "unsupported bit depth #{bits} (16-bit PCM only)" unless bits == 16

  samples = pcm.unpack("s<*")
  case channels
  when 1
    [[samples], samplerate]
  when 2
    frames = samples.length / 2
    left = Array.new(frames)
    right = Array.new(frames)
    i = 0
    while i < frames
      left[i] = samples[i * 2]
      right[i] = samples[i * 2 + 1]
      i += 1
    end
    if force_mono
      mono = Array.new(frames)
      i = 0
      while i < frames
        mono[i] = (left[i] + right[i]) / 2
        i += 1
      end
      [[mono], samplerate]
    else
      [[left, right], samplerate]
    end
  else
    raise "unsupported channel count #{channels}"
  end
end

# Encode one slice (up to 20 samples starting at offset) with the
# scalefactor giving the least squared error. Returns [slice_u64,
# best_lms, best_scalefactor]. prev_scalefactor seeds the search order.
def encode_slice(samples, offset, count, lms, prev_scalefactor)
  best_error = nil
  best_slice = nil
  best_lms = nil
  best_sf = 0

  16.times do |sfi|
    sf = (sfi + prev_scalefactor) % 16
    trial = lms.dup
    slice = sf
    error = 0
    count.times do |i|
      sample = samples[offset + i]
      predicted = trial.predict
      residual = sample - predicted
      scaled = clamp(qoa_div(residual, sf), -8, 8)
      quantized = QOA_QUANT_TAB[scaled + 8]
      dequantized = QOA_DEQUANT_TAB[sf][quantized]
      reconstructed = clamp(predicted + dequantized, -32768, 32767)
      delta = sample - reconstructed
      error += delta * delta
      trial.update(reconstructed, dequantized)
      slice = (slice << 3) | quantized
    end
    slice <<= (QOA_SLICE_LEN - count) * 3
    if best_error.nil? || error < best_error
      best_error = error
      best_slice = slice
      best_lms = trial
      best_sf = sf
    end
  end

  [best_slice, best_lms, best_sf]
end

def encode_qoa(channel_samples, samplerate)
  channels = channel_samples.length
  total = channel_samples[0].length
  out = ["qoaf", total].pack("a4N")
  lms = Array.new(channels) { Lms.new }
  prev_sf = Array.new(channels, 0)

  offset = 0
  while offset < total
    frame_samples = [QOA_FRAME_LEN, total - offset].min
    slices = (frame_samples + QOA_SLICE_LEN - 1) / QOA_SLICE_LEN
    frame_size = 8 + channels * 16 + slices * channels * 8
    out << [channels, samplerate >> 16, samplerate & 0xFFFF, frame_samples, frame_size].pack("CCnnn")
    channels.times do |c|
      out << lms[c].history.pack("s>4")
      out << lms[c].weights.pack("s>4")
    end
    slices.times do |s|
      count = [QOA_SLICE_LEN, frame_samples - s * QOA_SLICE_LEN].min
      channels.times do |c|
        slice, best_lms, sf = encode_slice(channel_samples[c], offset + s * QOA_SLICE_LEN,
                                           count, lms[c], prev_sf[c])
        lms[c] = best_lms
        prev_sf[c] = sf
        out << [slice].pack("Q>")
      end
    end
    offset += frame_samples
  end
  out
end

# Reference decoder for --verify. Returns per-channel sample arrays.
def decode_qoa(data)
  raise "bad magic" unless data[0, 4] == "qoaf"
  total = data[4, 4].unpack1("N")
  channels = nil
  decoded = nil
  done = 0
  pos = 8
  while done < total && pos + 8 <= data.bytesize
    frame_channels, _sr_hi, _sr_lo, frame_samples, frame_size = data[pos, 8].unpack("CCnnn")
    channels ||= frame_channels
    decoded ||= Array.new(channels) { [] }
    raise "channel count changed mid-stream" unless frame_channels == channels
    lms = Array.new(channels) { Lms.new }
    channels.times do |c|
      lms[c].history = data[pos + 8 + c * 16, 8].unpack("s>4")
      lms[c].weights = data[pos + 16 + c * 16, 8].unpack("s>4")
    end
    slice_pos = pos + 8 + channels * 16
    remaining = [frame_samples, total - done].min
    while remaining > 0
      count = [QOA_SLICE_LEN, remaining].min
      channels.times do |c|
        slice = data[slice_pos, 8].unpack1("Q>")
        slice_pos += 8
        sf = slice >> 60
        count.times do |i|
          predicted = lms[c].predict
          quantized = (slice >> (57 - i * 3)) & 7
          dequantized = QOA_DEQUANT_TAB[sf][quantized]
          sample = clamp(predicted + dequantized, -32768, 32767)
          lms[c].update(sample, dequantized)
          decoded[c] << sample
        end
      end
      remaining -= count
      done += count
    end
    pos += frame_size
  end
  decoded
end

input_path = nil
output_path = nil
verify = false
force_mono = false

i = 0
while i < ARGV.length
  case ARGV[i]
  when "-o"
    i += 1
    output_path = ARGV[i]
  when "--verify"
    verify = true
  when "--mono"
    force_mono = true
  else
    input_path = ARGV[i]
  end
  i += 1
end

unless input_path
  $stderr.puts "Usage: #{$0} input.wav [-o output.qoa] [--mono] [--verify]"
  exit 1
end

output_path ||= input_path.sub(/\.wav$/i, "") + ".qoa"

channel_samples, samplerate = read_wav(input_path, force_mono: force_mono)
channels = channel_samples.length
total = channel_samples[0].length
qoa = encode_qoa(channel_samples, samplerate)
File.binwrite(output_path, qoa)

seconds = total.to_f / samplerate
raw_size = total * 2 * channels
puts format("%s: %d frames, %d Hz, %s, %.2fs", input_path, total, samplerate,
            channels == 2 ? "stereo" : "mono", seconds)
puts format("%s: %d bytes (%.1f%% of 16-bit PCM, %.1f kbit/s)", output_path, qoa.bytesize,
            100.0 * qoa.bytesize / raw_size, qoa.bytesize * 8 / seconds / 1000.0)

if verify
  decoded = decode_qoa(qoa)
  raise "channel mismatch: #{decoded.length} != #{channels}" if decoded.length != channels

  error = 0.0
  count = 0
  channels.times do |c|
    raise "length mismatch: #{decoded[c].length} != #{total}" if decoded[c].length != total
    channel_samples[c].each_with_index do |s, j|
      d = s - decoded[c][j]
      error += d.to_f * d
    end
    count += total
  end
  mse = error / count
  psnr = mse > 0 ? 10 * Math.log10(32768.0 * 32768.0 / mse) : Float::INFINITY
  puts format("verify: PSNR %.1f dB", psnr)
end
