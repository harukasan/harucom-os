# Synth::DrumKit: the board's drum kit as synthesis definitions. The
# same definitions render on the host (scripts/gen_drumkit.rb writes
# them to rootfs/data/drums) and on the board:
#
#   kick = PWMAudio::Sample.new(Synth::DrumKit.render("bd"))
#
# Every sound is computed from elementary DSP, so no third-party audio
# enters the repository.
require "synth"

module Synth
  module DrumKit
    @definitions = {}

    class << self
      attr_reader :definitions
    end

    def self.define(name, &block)
      @definitions[name] = block
    end

    def self.names
      @definitions.keys
    end

    # Render one sound to a WAV String.
    def self.render(name, rate: 44100, seed: Synth::DEFAULT_SEED)
      block = @definitions[name]
      raise ArgumentError, "unknown drum #{name}" unless block
      Synth.render(rate: rate, seed: seed, &block)
    end

    define("bd") do
      sweep(0.28, from: 160.0, to: 44.0, curve: 28.0, decay: 12.0) +
        noise(0.02, decay: 300.0).highpass(900.0) * 0.5
    end

    define("sd") do
      sweep(0.18, from: 220.0, to: 168.0, curve: 40.0, decay: 24.0) * 0.6 +
        noise(0.22, decay: 14.0).highpass(1600.0) * 0.85
    end

    define("hh") do
      # 808 signal path: the square stack goes through a resonant
      # bandpass and a highpass, so only the 8-10 kHz hash remains.
      metallic(0.09, decay: 46.0).bandpass(10000.0, q: 1.2).highpass(8000.0)
    end

    define("oh") do
      metallic(0.45, decay: 7.5).bandpass(10000.0, q: 1.2).highpass(8000.0)
    end

    define("cp") do
      # Tight pre-attacks into an accented final burst and tail, all
      # windows over one band-shaped noise: the resonance around
      # 1.1 kHz gives the crack, a touch of high noise keeps the air.
      base = noise(0.28)
      source = base.bandpass(1100.0, q: 1.6) * 3.2 + base.highpass(5000.0) * 0.4
      source.env(220.0, cut: 0.009, level: 0.75) +
        source.env(220.0, at: 0.009, cut: 0.009, level: 0.85) +
        source.env(220.0, at: 0.018) +
        source.env(18.0, at: 0.021, level: 0.75)
    end

    define("lt") do
      sweep(0.32, from: 142.5, to: 95.0, curve: 18.0, decay: 9.5) +
        noise(0.015, decay: 350.0).highpass(1200.0) * 0.25
    end

    define("ht") do
      sweep(0.32, from: 240.0, to: 160.0, curve: 18.0, decay: 9.5) +
        noise(0.015, decay: 350.0).highpass(1200.0) * 0.25
    end

    define("rim") do
      sweep(0.05, from: 1700.0, decay: 90.0) * 0.7 +
        noise(0.008, decay: 500.0).highpass(2500.0) * 0.6
    end
  end
end
