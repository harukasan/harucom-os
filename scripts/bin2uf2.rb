# Convert a raw binary into UF2 blocks at a fixed flash address, so
# data files (the lumica QOA song) ride the combined UF2 and flash in
# the same BOOTSEL drop as the firmware (see merge_uf2.rb).
#
# UF2 spec: https://github.com/microsoft/uf2
#
# Usage:
#   ruby bin2uf2.rb -o OUTPUT -a 0x10400000 INPUT.bin

require "optparse"

BLOCK_SIZE = 512
HEADER_SIZE = 32
PAYLOAD_AREA = 476
PAYLOAD_SIZE = 256
END_MAGIC_SIZE = 4

UF2_MAGIC_START0 = 0x0A324655  # "UF2\n"
UF2_MAGIC_START1 = 0x9E5D5157
UF2_MAGIC_END    = 0x0AB16F30
UF2_FLAG_FAMILY_ID_PRESENT = 0x00002000
UF2_FAMILY_RP2350_ARM_S = 0xe48bff59

output_path = nil
address = nil
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} -o OUTPUT -a ADDRESS INPUT.bin"
  opts.on("-o FILE", "Output UF2 file") { |f| output_path = f }
  opts.on("-a ADDR", "Flash target address (e.g. 0x10400000)") do |a|
    address = Integer(a)
  end
end.parse!

abort "Error: -o output file required" unless output_path
abort "Error: -a address required" unless address
abort "Error: address must be 256-byte aligned" unless (address % PAYLOAD_SIZE).zero?
input_path = ARGV[0]
abort "Error: input binary required" unless input_path
abort "Error: input not found: #{input_path}" unless File.exist?(input_path)

data = File.binread(input_path)
abort "Error: #{input_path} is empty" if data.empty?
num_blocks = (data.bytesize + PAYLOAD_SIZE - 1) / PAYLOAD_SIZE

out = String.new(encoding: "BINARY")
num_blocks.times do |i|
  payload = data.byteslice(i * PAYLOAD_SIZE, PAYLOAD_SIZE)
  payload += "\x00".b * (PAYLOAD_SIZE - payload.bytesize)
  header = [
    UF2_MAGIC_START0,
    UF2_MAGIC_START1,
    UF2_FLAG_FAMILY_ID_PRESENT,
    address + i * PAYLOAD_SIZE,
    PAYLOAD_SIZE,
    i,
    num_blocks,
    UF2_FAMILY_RP2350_ARM_S,
  ].pack("V8")
  out << header << payload << "\x00".b * (PAYLOAD_AREA - PAYLOAD_SIZE)
  out << [UF2_MAGIC_END].pack("V")
end

File.binwrite(output_path, out)
$stderr.puts format("Wrote %d bytes (%d blocks) to %s at 0x%08x",
                    out.bytesize, num_blocks, output_path, address)
