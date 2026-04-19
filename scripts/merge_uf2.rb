# Merge multiple UF2 files into one.
#
# UF2 spec: https://github.com/microsoft/uf2
#
# Each UF2 block is 512 bytes with an independent flash target address, so
# files can be concatenated as long as no two blocks cover the same address
# range. After concatenation this script rewrites block_no (running index)
# and num_blocks (total count) so the output satisfies tools that verify
# those fields, such as picotool and the RP2350 BOOTSEL mass-storage loader.
#
# Usage:
#   ruby merge_uf2.rb -o OUTPUT INPUT1 INPUT2 [INPUT3 ...]

require "optparse"

BLOCK_SIZE = 512
HEADER_SIZE = 32
PAYLOAD_AREA = 476  # data region; actual payload is payload_size <= 476
END_MAGIC_SIZE = 4

UF2_MAGIC_START0 = 0x0A324655  # "UF2\n"
UF2_MAGIC_START1 = 0x9E5D5157
UF2_MAGIC_END    = 0x0AB16F30
UF2_FAMILY_RP2350_ARM_S = 0xe48bff59

Block = Struct.new(:magic0, :magic1, :flags, :target_addr, :payload_size,
                   :block_no, :num_blocks, :family_id, :payload, :end_magic,
                   :source_path, :source_index)

def parse_block(raw, source_path, source_index)
  unless raw.bytesize == BLOCK_SIZE
    abort "#{source_path}: block #{source_index} has #{raw.bytesize} bytes, expected #{BLOCK_SIZE}"
  end
  header = raw.byteslice(0, HEADER_SIZE).unpack("V8")
  end_magic = raw.byteslice(BLOCK_SIZE - END_MAGIC_SIZE, END_MAGIC_SIZE).unpack1("V")
  magic0, magic1, flags, target_addr, payload_size, block_no, num_blocks, family_id = header

  if magic0 != UF2_MAGIC_START0 || magic1 != UF2_MAGIC_START1 || end_magic != UF2_MAGIC_END
    abort "#{source_path}: block #{source_index} has invalid UF2 magic"
  end
  if family_id != UF2_FAMILY_RP2350_ARM_S
    abort format("%s: block %d has unsupported family id 0x%08x (expected 0x%08x)",
                 source_path, source_index, family_id, UF2_FAMILY_RP2350_ARM_S)
  end
  if payload_size > PAYLOAD_AREA
    abort "#{source_path}: block #{source_index} payload_size #{payload_size} exceeds #{PAYLOAD_AREA}"
  end

  payload = raw.byteslice(HEADER_SIZE, PAYLOAD_AREA)
  Block.new(magic0, magic1, flags, target_addr, payload_size, block_no,
            num_blocks, family_id, payload, end_magic, source_path, source_index)
end

def load_uf2(path)
  data = File.binread(path)
  unless (data.bytesize % BLOCK_SIZE).zero?
    abort "#{path}: size #{data.bytesize} is not a multiple of #{BLOCK_SIZE}"
  end
  block_count = data.bytesize / BLOCK_SIZE
  Array.new(block_count) do |i|
    parse_block(data.byteslice(i * BLOCK_SIZE, BLOCK_SIZE), path, i)
  end
end

def check_no_overlap(blocks)
  sorted = blocks.sort_by(&:target_addr)
  sorted.each_cons(2) do |a, b|
    a_end = a.target_addr + a.payload_size
    if a_end > b.target_addr
      abort format("address overlap: %s block %d [0x%08x-0x%08x) overlaps %s block %d [0x%08x-0x%08x)",
                   a.source_path, a.source_index, a.target_addr, a_end,
                   b.source_path, b.source_index, b.target_addr, b.target_addr + b.payload_size)
    end
  end
end

def pack_block(block, new_block_no, new_num_blocks)
  header = [
    block.magic0,
    block.magic1,
    block.flags,
    block.target_addr,
    block.payload_size,
    new_block_no,
    new_num_blocks,
    block.family_id,
  ].pack("V8")
  header + block.payload + [UF2_MAGIC_END].pack("V")
end

# -- Main --

output_path = nil
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} -o OUTPUT INPUT1 INPUT2 [INPUT3 ...]"
  opts.on("-o FILE", "Output UF2 file") { |f| output_path = f }
end.parse!

abort "Error: -o output file required" unless output_path
abort "Error: need at least 2 input UF2 files" if ARGV.size < 2
ARGV.each { |p| abort "Error: input not found: #{p}" unless File.exist?(p) }

all_blocks = ARGV.flat_map { |path| load_uf2(path) }
check_no_overlap(all_blocks)

total = all_blocks.size
out = String.new(encoding: "BINARY")
all_blocks.each_with_index do |block, i|
  out << pack_block(block, i, total)
end

File.binwrite(output_path, out)
$stderr.puts "Wrote #{out.bytesize} bytes (#{total} blocks) to #{output_path}"
