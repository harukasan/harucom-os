require "picotest"
# drum_kit first, so the test exercises its own require of synth (the
# board loads it standalone).
require "synth/drum_kit"

class SynthTest < Picotest::Test
  def wav_u32(data, offset)
    data[offset, 4].unpack("V")[0]
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

  def test_mix_spans_the_longer_operand
    a = Synth::Buffer.new([0.5, 0.5], 8000)
    b = Synth::Buffer.new([0.25], 8000)
    assert_equal [0.75, 0.5], (a + b).samples
  end

  def test_gain
    assert_equal [0.25, -0.25], (Synth::Buffer.new([0.5, -0.5], 8000) * 0.5).samples
  end

  def test_env_offset_and_cut
    source = Synth::Buffer.new(Array.new(10, 1.0), 1000)
    shaped = source.env(0.0, at: 0.003, cut: 0.004)
    assert_equal 0.0, shaped.samples[2]
    assert_equal 1.0, shaped.samples[3]
    assert_equal 1.0, shaped.samples[7]
    assert_equal 0.0, shaped.samples[8]
  end

  def test_normalize_and_fade_tail
    buffer = Synth::Buffer.new([0.1, -0.2, 0.1, 0.1], 1000).normalize(peak: 0.8)
    assert_equal(-0.8, buffer.samples[1])
    faded = buffer.fade_tail(ms: 2.0)
    assert_equal 0.0, faded.samples[3]
  end

  def test_drum_kit_renders_every_name
    names = Synth::DrumKit.names
    assert_equal 8, names.length
    i = 0
    while i < names.length
      wav = Synth::DrumKit.render(names[i], rate: 8000)
      assert_equal true, wav.bytesize > 44
      pcm = wav[44, wav.bytesize - 44].unpack("s<*")
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
end
