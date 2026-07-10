require "picotest"
# drum_kit first, so the test exercises its own require of synth (the
# board loads it standalone).
require "synth/drum_kit"

class SynthTest < Picotest::Test
  def wav_u32(data, offset)
    data[offset, 4].unpack("V")[0]
  end

  def pcm_of(wav)
    wav[44, wav.bytesize - 44].unpack("s<*")
  end

  def test_render_is_deterministic
    a = Synth.render(rate: 8000) { noise(0.02) }
    b = Synth.render(rate: 8000) { noise(0.02) }
    assert_equal a, b
  end

  def test_seed_changes_noise
    a = Synth.render(rate: 8000, seed: 1) { noise(0.02) }
    b = Synth.render(rate: 8000, seed: 2) { noise(0.02) }
    assert_equal false, a == b
  end

  def test_wav_header
    wav = Synth.render(rate: 8000) do
      silence(0.005) + sweep(0.01, from: 440.0, decay: 5.0)
    end
    assert_equal "RIFF", wav[0, 4]
    assert_equal "WAVE", wav[8, 4]
    assert_equal 8000, wav_u32(wav, 24)
    assert_equal wav.bytesize - 44, wav_u32(wav, 40)
    assert_equal 0, wav_u32(wav, 40) % 2
  end

  # Buffer unit tests build Arrays directly, so they pin the pure
  # backend; the flag is restored at the end of each.
  def test_mix_spans_the_longer_operand
    Synth.use_native = false
    a = Synth::Buffer.new([0.5, 0.5], 8000)
    b = Synth::Buffer.new([0.25], 8000)
    result = (a + b).samples
    Synth.use_native = true
    assert_equal [0.75, 0.5], result
  end

  def test_gain
    Synth.use_native = false
    result = (Synth::Buffer.new([0.5, -0.5], 8000) * 0.5).samples
    Synth.use_native = true
    assert_equal [0.25, -0.25], result
  end

  def test_env_offset_and_cut
    Synth.use_native = false
    source = Synth::Buffer.new(Array.new(10, 1.0), 1000)
    shaped = source.env(0.0, at: 0.003, cut: 0.004).samples
    Synth.use_native = true
    assert_equal 0.0, shaped[2]
    assert_equal 1.0, shaped[3]
    assert_equal 1.0, shaped[7]
    assert_equal 0.0, shaped[8]
  end

  def test_normalize_and_fade_tail
    Synth.use_native = false
    buffer = Synth::Buffer.new([0.1, -0.2, 0.1, 0.1], 1000).normalize(peak: 0.8)
    normalized = buffer.samples[1]
    faded = buffer.fade_tail(ms: 2.0).samples[3]
    Synth.use_native = true
    assert_equal(-0.8, normalized)
    assert_equal 0.0, faded
  end

  def test_drum_kit_renders_every_name
    names = Synth::DrumKit.names
    assert_equal 8, names.length
    i = 0
    while i < names.length
      wav = Synth::DrumKit.render(names[i], rate: 8000)
      assert_equal true, wav.bytesize > 44
      pcm = pcm_of(wav)
      peak = 0
      j = 0
      while j < pcm.length
        v = pcm[j]
        v = -v if v < 0
        peak = v if v > peak
        j += 1
      end
      # normalize targets 0.9 of full scale
      assert_equal true, peak >= 29000 && peak <= 29800
      i += 1
    end
  end

  def test_render_requires_a_buffer
    assert_raise(ArgumentError) do
      Synth.render(rate: 8000) { 42 }
    end
  end

  # The C kernels must produce the same sound as the Ruby kernels:
  # identical length, PCM within a small tolerance (float vs double).
  # cp covers the noise and filter kernels, hh covers the square
  # oscillator whose edge decisions must match between backends.
  def test_native_backend_matches_pure_ruby
    assert_equal true, Synth::NATIVE_AVAILABLE
    ["cp", "hh"].each do |name|
      Synth.use_native = false
      pure = Synth::DrumKit.render(name, rate: 8000)
      Synth.use_native = true
      native = Synth::DrumKit.render(name, rate: 8000)
      assert_equal pure.bytesize, native.bytesize
      a = pcm_of(pure)
      b = pcm_of(native)
      worst = 0
      i = 0
      while i < a.length
        d = a[i] - b[i]
        d = -d if d < 0
        worst = d if d > worst
        i += 1
      end
      assert_equal true, worst <= 64
    end
  end
end
