#!/usr/bin/env ruby
# Write the board's drum kit to WAV files on the host. The synthesis
# itself lives in the shared library (rootfs/lib/synth.rb and
# rootfs/lib/synth/drum_kit.rb), which also runs on the board, so the
# kit can be regenerated in either place and no third-party audio
# enters the repository.
#
# Usage: ruby scripts/gen_drumkit.rb [-o rootfs/data/drums] [--rate 44100]

require "optparse"
require "fileutils"

$LOAD_PATH.unshift File.expand_path("../rootfs/lib", __dir__)
require "synth"
require "synth/drum_kit"

outdir = "rootfs/data/drums"
rate = 44100
OptionParser.new do |opt|
  opt.on("-o DIR") { |v| outdir = v }
  opt.on("--rate RATE", Integer) { |v| rate = v }
end.parse!(ARGV)

FileUtils.mkdir_p(outdir)
total = 0
Synth::DrumKit.names.each do |name|
  wav = Synth::DrumKit.render(name, rate: rate)
  File.binwrite(File.join(outdir, "#{name}.wav"), wav)
  total += wav.bytesize
  seconds = (wav.bytesize - 44) / 2.0 / rate
  puts format("%-4s %6.3fs %6d bytes", name, seconds, wav.bytesize)
end
puts format("total %d bytes", total)
