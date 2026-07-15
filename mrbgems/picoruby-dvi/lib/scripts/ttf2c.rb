#!/usr/bin/env ruby
# frozen_string_literal: true

# TTF to C header converter for dvi_font_t.
# Uses FreeType to render glyphs at exact pixel size.
#
# Usage: ruby ttf2c.rb <input.ttf> [options]
#   -o FILE     Output file (default: stdout)
#   -n NAME     Font variable name (default: derived from filename)
#   -s SIZE     Pixel size (default: 12)
#   -r RANGE    Character range as "first-last" (default: 0x20-0x7f)
#   --jis       JIS X 0208 mode: generate JIS-indexed font via Unicode mapping
#   --aa        Anti-aliased 4bpp rendering

require "optparse"
require "freetype"
require "erb"

# --- Compressed JIS font support (canonical Huffman + zero-run RLE) ---
#
# Symbol alphabet (must match the decoder in dvi_graphics_text.c):
#   0        : unused
#   1..15    : literal 4bpp nibble value
#   16..31   : run of (symbol - 15) zero pixels (length 1..16)
#
# Each glyph is trimmed to its ink bounding box, its 4bpp pixels are scanned
# row-major into zero-run/literal tokens, and the tokens are written as a
# canonical Huffman bitstream (MSB first, byte-aligned per glyph). One shared
# Huffman table (code lengths per symbol) is emitted for the whole font.
HUFF_ALPHABET = 32
HUFF_MAXBITS  = 24

# Tight ink bounding box of a 4bpp pixel grid. Returns [x, y, w, h] or nil.
def ink_bbox(pixels, gw, gh)
  top = nil; bottom = 0; left = gw; right = 0
  gh.times do |r|
    row = pixels[r]
    gw.times do |c|
      next if row[c] == 0
      top = r if top.nil?
      bottom = r
      left = c if c < left
      right = c if c > right
    end
  end
  return nil if top.nil?
  [left, top, right - left + 1, bottom - top + 1]
end

# Tokenize the trimmed bbox region into symbols (row-major).
def tokenize_bbox(pixels, bx, by, bw, bh)
  toks = []
  bh.times do |r|
    row = pixels[by + r]
    c = 0
    while c < bw
      v = row[bx + c]
      if v == 0
        run = 0
        run += 1 while (c + run) < bw && row[bx + c + run] == 0
        rem = run
        while rem > 0
          m = rem > 16 ? 16 : rem
          toks << (15 + m) # zero-run symbol (16..31)
          rem -= m
        end
        c += run
      else
        toks << v          # literal nibble (1..15)
        c += 1
      end
    end
  end
  toks
end

# Huffman code lengths from symbol frequencies.
def huffman_lengths(freq)
  lengths = Array.new(freq.length, 0)
  present = (0...freq.length).select { |s| freq[s] > 0 }
  return lengths if present.empty?
  if present.length == 1
    lengths[present[0]] = 1
    return lengths
  end
  nodes = present.map { |s| { w: freq[s], sym: s } }
  until nodes.length == 1
    nodes.sort_by! { |n| n[:w] }
    a = nodes.shift
    b = nodes.shift
    nodes << { w: a[:w] + b[:w], l: a, r: b }
  end
  stack = [[nodes[0], 0]]
  until stack.empty?
    node, depth = stack.pop
    if node[:sym]
      lengths[node[:sym]] = depth
    else
      stack << [node[:l], depth + 1]
      stack << [node[:r], depth + 1]
    end
  end
  lengths
end

# Canonical Huffman codes (RFC 1951 3.2.2) from code lengths.
def canonical_codes(lengths, maxbits)
  bl_count = Array.new(maxbits + 1, 0)
  lengths.each { |l| bl_count[l] += 1 if l > 0 }
  code = 0
  next_code = Array.new(maxbits + 1, 0)
  (1..maxbits).each do |bits|
    code = (code + bl_count[bits - 1]) << 1
    next_code[bits] = code
  end
  codes = Array.new(lengths.length, 0)
  lengths.each_index do |s|
    l = lengths[s]
    next if l == 0
    codes[s] = next_code[l]
    next_code[l] += 1
  end
  codes
end

# MSB-first bit accumulator producing byte-aligned output.
class BitBuffer
  def initialize
    @bytes = []
    @cur = 0
    @n = 0
  end

  def put(code, len)
    (len - 1).downto(0) do |i|
      @cur = (@cur << 1) | ((code >> i) & 1)
      @n += 1
      if @n == 8
        @bytes << @cur
        @cur = 0
        @n = 0
      end
    end
  end

  def finish
    if @n > 0
      @cur <<= (8 - @n)
      @bytes << @cur
      @cur = 0
      @n = 0
    end
    @bytes
  end
end

# Build the canonical decode table (count/symbol) exactly as the C decoder does.
def build_decode_table(lengths, maxbits)
  count = Array.new(maxbits + 1, 0)
  lengths.each { |l| count[l] += 1 }
  count[0] = 0
  offs = Array.new(maxbits + 2, 0)
  (1..maxbits - 1).each { |len| offs[len + 1] = offs[len] + count[len] }
  symbol = Array.new(lengths.length, 0)
  lengths.each_index do |s|
    next if lengths[s] == 0
    symbol[offs[lengths[s]]] = s
    offs[lengths[s]] += 1
  end
  [count, symbol]
end

# Decode a glyph the same way the C renderer will. Returns w*h nibbles.
def decode_glyph(blob, offset, npixels, count, symbol, maxbits)
  out = []
  bytepos = offset
  bitpos = 0
  while out.length < npixels
    code = 0; first = 0; index = 0; sym = nil
    len = 1
    while len <= maxbits
      bit = (blob[bytepos] >> (7 - bitpos)) & 1
      bitpos += 1
      if bitpos == 8
        bitpos = 0
        bytepos += 1
      end
      code |= bit
      cnt = count[len]
      if code - first < cnt
        sym = symbol[index + (code - first)]
        break
      end
      index += cnt
      first = (first + cnt) << 1
      code <<= 1
      len += 1
    end
    raise "decode failure" if sym.nil?
    if sym < 16
      out << sym
    else
      (sym - 15).times { out << 0 }
    end
  end
  out
end

COMPRESSED_TEMPLATE = ERB.new(<<~'TEMPLATE', trim_mode: "-")
  // Generated by ttf2c.rb (<%= generator_comment %>)
  #ifndef <%= guard %>
  #define <%= guard %>

  #include "dvi_font.h"

  static const uint8_t font_<%= font_name %>_blob[] = {
  <% blob.each_slice(20) do |chunk| -%>
      <%= chunk.map { |b| "0x%02x" % b }.join(",") %>,
  <% end -%>
  };

  static const uint32_t font_<%= font_name %>_offsets[<%= num_chars %>] = {
  <% offsets.each_slice(12) do |chunk| -%>
      <%= chunk.join(", ") %>,
  <% end -%>
  };

  static const uint8_t font_<%= font_name %>_bbox[<%= num_chars * 4 %>] = {
  <% glyph_bbox.each_slice(8) do |chunk| -%>
      <%= chunk.map { |b| "%d,%d,%d,%d" % [b[0], b[1], b[2], b[3]] }.join(", ") %>,
  <% end -%>
  };

  static const uint8_t font_<%= font_name %>_huff[<%= HUFF_ALPHABET %>] = {
      <%= lengths.join(", ") %>
  };

  static const dvi_font_t font_<%= font_name %> = {
      .glyph_width   = <%= full_advance %>,
      .glyph_height  = <%= glyph_height %>,
      .first_char    = 0,
      .num_chars     = <%= num_chars %>,
      .bitmap        = font_<%= font_name %>_blob,
      .glyph_stride  = 0,
      .bpp           = 4,
      .bitmap_left   = <%= min_left %>,
      .compression   = 1,
      .glyph_offsets = font_<%= font_name %>_offsets,
      .glyph_bbox    = font_<%= font_name %>_bbox,
      .huff_table    = font_<%= font_name %>_huff,
  };

  #endif
TEMPLATE

options = {
  name: nil,
  output: nil,
  size: 12,
  range: "0x20-0x7f",
  jis: false,
  aa: false,
  compress: false,
  ascent: nil,
  chars_files: [],
  jis_rows: nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} <input.ttf> [options]"
  opts.on("-o FILE", "Output file") { |f| options[:output] = f }
  opts.on("-n NAME", "Font variable name") { |n| options[:name] = n }
  opts.on("-s SIZE", Integer, "Pixel size") { |s| options[:size] = s }
  opts.on("-r RANGE", "Character range (e.g., 0x20-0x7f)") { |r| options[:range] = r }
  opts.on("--jis", "JIS X 0208 mode") { options[:jis] = true }
  opts.on("--aa", "Anti-aliased 4bpp rendering") { options[:aa] = true }
  opts.on("--compress", "Compress glyphs (Huffman + zero-run, JIS+AA only)") { options[:compress] = true }
  opts.on("--ascent N", Integer, "Force baseline row (align with another font)") { |n| options[:ascent] = n }
  opts.on("--chars FILE", "Subset JIS glyphs to characters used in FILE (repeatable)") { |f| options[:chars_files] << f }
  opts.on("--jis-rows LIST", "Always include these JIS rows (e.g. \"1-5\" or \"1,2,4\")") { |l| options[:jis_rows] = l }
end.parse!

input_path = ARGV[0] or abort "Error: no input TTF file specified"
font_name = options[:name] || File.basename(input_path, ".*").gsub(/[^a-zA-Z0-9_]/, "_")

font = FreeType::API::Font.open(input_path)
font.set_char_size(0, options[:size] * 64, 72, 72)

# Load a glyph with FT_LOAD_RENDER for outline fonts.
# Returns the FreeType glyph slot with rendered bitmap.
def load_rendered_glyph(font, codepoint, mono: true)
  flags = FreeType::C::FT_LOAD_RENDER
  flags |= FreeType::C::FT_LOAD_MONOCHROME if mono
  err = FreeType::C::FT_Load_Char(font.face, codepoint, flags)
  raise "FT_Load_Char failed for codepoint #{codepoint}: error #{err}" unless err == 0
  font.face[:glyph]
end

# Render a 1bpp glyph and return {rows:, width:, advance:}
# Bitmap rows are MSB-first, padded to full bytes.
# ascender is the baseline position in pixels from the top of the glyph cell.
def render_glyph(font, codepoint, target_height, glyph_width, ascender: nil)
  g = load_rendered_glyph(font, codepoint, mono: true)
  bm = g[:bitmap]
  w = bm[:width]
  h = bm[:rows]
  advance = g[:advance][:x] >> 6
  bitmap_top = g[:bitmap_top]
  bitmap_left = g[:bitmap_left]

  # Place into target_height bitmap.
  # bitmap_top = distance from baseline to top of bitmap.
  # Baseline is at ascender pixels from top (or target_height - 1 as fallback).
  baseline = ascender || (target_height - 1)
  y_start = baseline - bitmap_top

  src_bytes_per_row = (w + 7) / 8
  dst_bytes_per_row = (glyph_width + 7) / 8
  buf = bm[:buffer]

  # Shift to position glyph at bitmap_left within glyph_width storage.
  # FreeType bitmap is MSB-aligned within src_bytes_per_row.
  shift = (dst_bytes_per_row - src_bytes_per_row) * 8 - bitmap_left

  rows = Array.new(target_height, 0)
  h.times do |src_y|
    dst_y = y_start + src_y
    next if dst_y < 0 || dst_y >= target_height

    # Read source row
    val = 0
    src_bytes_per_row.times do |b|
      val = (val << 8) | buf.get_uint8(src_y * bm[:pitch] + b)
    end

    val = shift > 0 ? (val << shift) : (val >> -shift)

    # Mask to glyph_width
    mask = ((1 << glyph_width) - 1) << (dst_bytes_per_row * 8 - glyph_width)
    rows[dst_y] = val & mask
  end

  {rows: rows, width: w, advance: advance}
end

# Render a 4bpp anti-aliased glyph and return {pixels:, width:, advance:, bitmap_left:}
# pixels is a 2D array [row][col] of 4-bit alpha values (0-15).
# ascender is the baseline position in pixels from the top of the glyph cell.
# left_offset shifts all glyphs right by -left_offset to accommodate negative bearing.
def render_glyph_aa(font, codepoint, target_height, glyph_width, ascender: nil, left_offset: 0)
  g = load_rendered_glyph(font, codepoint, mono: false)
  bm = g[:bitmap]
  w = bm[:width]
  h = bm[:rows]
  advance = g[:advance][:x] >> 6
  bitmap_top = g[:bitmap_top]
  bitmap_left = g[:bitmap_left]

  baseline = ascender || (target_height - 1)
  y_start = baseline - bitmap_top
  buf = bm[:buffer]
  pitch = bm[:pitch]

  pixels = Array.new(target_height) { Array.new(glyph_width, 0) }
  h.times do |src_y|
    dst_y = y_start + src_y
    next if dst_y < 0 || dst_y >= target_height

    w.times do |src_x|
      dst_x = bitmap_left - left_offset + src_x
      next if dst_x < 0 || dst_x >= glyph_width

      # FreeType grayscale: 8bpp, one byte per pixel
      gray = buf.get_uint8(src_y * pitch + src_x)
      # Quantize 8bpp (0-255) to 4bpp (0-15)
      pixels[dst_y][dst_x] = (gray + 8) / 17
    end
  end

  {pixels: pixels, width: w, advance: advance, bitmap_left: bitmap_left}
end

# Determine max glyph dimensions for the character set.
# Returns [glyph_width, glyph_height, ascender_pixels, min_left].
# glyph_width covers the full extent from min(bitmap_left) to max(bitmap_left + bitmap_width).
# min_left is the minimum bitmap_left across all glyphs (0 or negative).
def scan_dimensions(font, codepoints, pixel_size, mono: true)
  min_left = 0
  max_right = 0
  codepoints.each do |cp|
    g = load_rendered_glyph(font, cp, mono: mono)
    bm = g[:bitmap]
    left = g[:bitmap_left]
    right = left + bm[:width]
    min_left = left if left < min_left
    max_right = right if right > max_right
  end
  metrics = font.face[:size][:metrics]
  ascender = (metrics[:ascender] + 63) >> 6   # round up
  descender = (-metrics[:descender] + 63) >> 6 # round up (descender is negative)
  glyph_height = ascender + descender
  glyph_width = max_right - min_left
  [glyph_width, glyph_height, ascender, min_left]
end

def pack_rows(rows, glyph_width)
  bytes_per_row = (glyph_width + 7) / 8
  rows.flat_map do |row|
    # Shift row to fill glyph_width from MSB
    bytes_per_row.times.map do |b|
      (row >> (8 * (bytes_per_row - 1 - b))) & 0xFF
    end
  end
end

# Pack 4bpp pixel data: 2 pixels per byte, high nibble = left pixel.
def pack_pixels_4bpp(pixels, glyph_width)
  bytes_per_row = (glyph_width + 1) / 2
  pixels.flat_map do |row|
    bytes_per_row.times.map do |b|
      left = row[b * 2] || 0
      right = row[b * 2 + 1] || 0
      (left << 4) | right
    end
  end
end

# Parse a row list like "1-5" or "1,2,4-8" into an array of row numbers.
def parse_jis_rows(list)
  list.split(",").flat_map do |part|
    if part.include?("-")
      first, last = part.split("-").map { |n| Integer(n) }
      (first..last).to_a
    else
      [Integer(part)]
    end
  end
end

# Build the set of JIS linear indices to render, or nil for full coverage.
# The subset is the union of whole JIS rows (jis_rows) and every character
# found in the given files (chars_files) that maps to JIS X 0208.
def build_jis_subset(uni2jis, chars_files, jis_rows)
  return nil if chars_files.empty? && jis_rows.nil?
  subset = {}
  if jis_rows
    parse_jis_rows(jis_rows).each do |ku|
      abort "Error: JIS row #{ku} out of range 1..94" unless (1..94).cover?(ku)
      94.times { |ten| subset[(ku - 1) * 94 + ten] = true }
    end
  end
  chars_files.each do |file|
    File.read(file, encoding: "UTF-8").each_char do |ch|
      idx = uni2jis[ch.ord]
      subset[idx] = true if idx
    end
  end
  subset
end

# Build Unicode -> JIS linear index mapping
def build_unicode_to_jis_map
  map = {}
  (1..94).each do |ku|
    (1..94).each do |ten|
      euc = [ku + 0xA0, ten + 0xA0].pack("CC").force_encoding("EUC-JP")
      begin
        cp = euc.encode("UTF-8").ord
        map[cp] = (ku - 1) * 94 + (ten - 1)
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
        next
      end
    end
  end
  map
end

HEADER_TEMPLATE = ERB.new(<<~'TEMPLATE', trim_mode: "-")
// Generated by ttf2c.rb (<%= generator_comment %>)
#ifndef <%= guard %>
#define <%= guard %>

#include "dvi_font.h"

static const uint8_t font_<%= font_name %>_bitmap[] = {
<% glyphs.each do |g| -%>
    <%= g[:bytes].map { |b| "0x%02x" % b }.join(", ") %>,  // <%= g[:comment] %>
<% end -%>
};
<% if is_proportional -%>

static const uint8_t font_<%= font_name %>_widths[] = {
<% advances.each_slice(16) do |chunk| -%>
    <%= chunk.map { |v| "%2d" % v }.join(", ") %>,
<% end -%>
};
<% end -%>

static const dvi_font_t font_<%= font_name %> = {
    .glyph_width  = <%= glyph_width %>,
    .glyph_height = <%= glyph_height %>,
    .first_char   = <%= first_char_hex %>,
    .num_chars    = <%= num_chars %>,
    .bitmap       = font_<%= font_name %>_bitmap,
<% if is_proportional -%>
    .widths       = font_<%= font_name %>_widths,
<% end -%>
<% if font_bpp && font_bpp > 1 -%>
    .glyph_stride = <%= glyph_stride %>,
    .bpp          = <%= font_bpp %>,
    .bitmap_left  = <%= bitmap_left_value %>,
<% end -%>
};

#endif
TEMPLATE

font_bpp = options[:aa] ? 4 : nil
glyph_stride = nil
bitmap_left_value = 0

if options[:jis]
  # JIS mode: generate JIS-indexed font from Unicode TTF
  uni2jis = build_unicode_to_jis_map
  num_chars = 94 * 94

  subset = build_jis_subset(uni2jis, options[:chars_files], options[:jis_rows])
  uni2jis = uni2jis.select { |_cp, idx| subset[idx] } if subset

  jis_codepoints = uni2jis.keys
  glyph_width, glyph_height, ascender, min_left = scan_dimensions(font, jis_codepoints, options[:size], mono: !options[:aa])
  # Force the baseline row to align with another font (keep the taller cell so
  # nothing is clipped; the ink bounding box trims the extra rows anyway).
  ascender = options[:ascent] if options[:ascent]
  bitmap_left_value = min_left if options[:aa]
  bytes_per_row = options[:aa] ? (glyph_width + 1) / 2 : (glyph_width + 7) / 8
  bytes_per_glyph = bytes_per_row * glyph_height
  glyph_stride = bytes_per_glyph if options[:aa]

  jis2uni = {}
  uni2jis.each { |cp, idx| jis2uni[idx] = cp }

  rendered = {}
  advances = {}
  jis2uni.each do |idx, cp|
    # Leave characters the font lacks blank instead of rendering .notdef (tofu).
    next if FreeType::C::FT_Get_Char_Index(font.face, cp) == 0
    if options[:aa]
      r = render_glyph_aa(font, cp, glyph_height, glyph_width, ascender: ascender, left_offset: min_left)
      rendered[idx] = r
      # Clamp advance to cover this glyph's own bitmap extent
      advances[idx] = [r[:advance], r[:bitmap_left] + r[:width]].max
    else
      r = render_glyph(font, cp, glyph_height, glyph_width, ascender: ascender)
      rendered[idx] = r
      advances[idx] = r[:advance]
    end
  end

  if options[:compress]
    abort "--compress requires --aa" unless options[:aa]

    # Fixed full-width advance = the most common per-glyph advance.
    adv_hist = Hash.new(0)
    advances.each_value { |a| adv_hist[a] += 1 }
    full_advance = adv_hist.max_by { |_, n| n }[0]

    # Pass 1: trim to ink bbox, tokenize, gather symbol frequencies.
    freq = Array.new(HUFF_ALPHABET, 0)
    glyph_tokens = Array.new(num_chars)
    glyph_bbox = Array.new(num_chars) { [0, 0, 0, 0] }
    num_chars.times do |idx|
      r = rendered[idx]
      next unless r
      bbox = ink_bbox(r[:pixels], glyph_width, glyph_height)
      next unless bbox
      bx, by, bw, bh = bbox
      toks = tokenize_bbox(r[:pixels], bx, by, bw, bh)
      glyph_tokens[idx] = toks
      glyph_bbox[idx] = bbox
      toks.each { |t| freq[t] += 1 }
    end

    lengths = huffman_lengths(freq)
    maxlen = lengths.max
    abort "Huffman code length #{maxlen} exceeds #{HUFF_MAXBITS}" if maxlen > HUFF_MAXBITS
    codes = canonical_codes(lengths, HUFF_MAXBITS)

    # Pass 2: encode each glyph (byte-aligned), sharing identical bitstreams.
    blob = []
    offsets = Array.new(num_chars, 0)
    dedup = {}
    num_chars.times do |idx|
      toks = glyph_tokens[idx]
      next if toks.nil? # blank glyph: offset unused (bbox w==0)
      buf = BitBuffer.new
      toks.each { |t| buf.put(codes[t], lengths[t]) }
      bytes = buf.finish
      key = [glyph_bbox[idx], bytes]
      if (off = dedup[key])
        offsets[idx] = off
      else
        offsets[idx] = blob.length
        blob.concat(bytes)
        dedup[key] = offsets[idx]
      end
    end

    # Self-test: decode every glyph exactly as the C renderer will.
    # The FNV-1a digest over decoded pixels lets a host C build confirm its
    # decoder matches this one (see the cross-check in the build docs).
    count, symbol = build_decode_table(lengths, HUFF_MAXBITS)
    populated = 0
    fnv = 1469598103934665603
    mask = (1 << 64) - 1
    num_chars.times do |idx|
      next if glyph_tokens[idx].nil?
      populated += 1
      bx, by, bw, bh = glyph_bbox[idx]
      expected = []
      bh.times { |r| bw.times { |c| expected << rendered[idx][:pixels][by + r][bx + c] } }
      got = decode_glyph(blob, offsets[idx], bw * bh, count, symbol, HUFF_MAXBITS)
      abort "self-test mismatch at glyph #{idx}" unless got == expected
      got.each { |v| fnv = ((fnv ^ v) * 1099511628211) & mask }
    end
    $stderr.puts "self-test OK, FNV=#{fnv}"

    guard = "DVI_FONT_#{font_name.upcase}_H"
    generator_comment = "compressed JIS X 0208, 4bpp AA, canonical Huffman + zero-run"
    result = COMPRESSED_TEMPLATE.result(binding)
    if options[:output]
      File.write(options[:output], result)
      $stderr.puts "Wrote #{options[:output]}"
    else
      print result
    end
    raw = populated * ((glyph_width + 1) / 2) * glyph_height
    $stderr.puts "compressed JIS: #{populated} glyphs, blob=#{blob.length}B " \
                 "(raw 4bpp #{raw}B, #{"%.1f" % (100.0 * blob.length / raw)}%), " \
                 "advance=#{full_advance}, cell=#{glyph_width}x#{glyph_height}, huffmax=#{maxlen}"
    exit 0
  end

  is_proportional = advances.values.uniq.length > 1
  first_char_hex = "0"

  glyphs = num_chars.times.map do |idx|
    r = rendered[idx]
    if options[:aa]
      bytes = r ? pack_pixels_4bpp(r[:pixels], glyph_width) : Array.new(bytes_per_glyph, 0)
    else
      bytes = r ? pack_rows(r[:rows], glyph_width) : Array.new(bytes_per_glyph, 0)
    end
    ku = idx / 94 + 1
    ten = idx % 94 + 1
    {bytes: bytes, comment: "idx=%d ku=%d ten=%d" % [idx, ku, ten]}
  end

  advances = num_chars.times.map { |idx| advances[idx] || glyph_width }

  generator_comment = "JIS X 0208, from TTF via FreeType"
  populated = rendered.size
  bpp_label = options[:aa] ? ", 4bpp" : ""
  $stderr.puts "JIS mode: #{populated}/#{num_chars} slots, #{glyph_width}x#{glyph_height}, proportional=#{is_proportional}#{bpp_label}"

else
  # ASCII/Latin mode
  range_parts = options[:range].split("-")
  first_char = Integer(range_parts[0])
  last_char = Integer(range_parts[1])
  codepoints = (first_char..last_char).to_a
  num_chars = last_char - first_char + 1

  glyph_width, glyph_height, ascender, min_left = scan_dimensions(font, codepoints, options[:size], mono: !options[:aa])
  bitmap_left_value = min_left if options[:aa]
  bytes_per_row = options[:aa] ? (glyph_width + 1) / 2 : (glyph_width + 7) / 8
  glyph_stride = bytes_per_row * glyph_height if options[:aa]

  advances = []
  glyphs = codepoints.map do |cp|
    if options[:aa]
      r = render_glyph_aa(font, cp, glyph_height, glyph_width, ascender: ascender, left_offset: min_left)
      bytes = pack_pixels_4bpp(r[:pixels], glyph_width)
      # Clamp advance to cover this glyph's own bitmap extent
      advances << [r[:advance], r[:bitmap_left] + r[:width]].max
    else
      r = render_glyph(font, cp, glyph_height, glyph_width, ascender: ascender)
      bytes = pack_rows(r[:rows], glyph_width)
      advances << r[:advance]
    end
    comment = cp >= 0x20 && cp <= 0x7E ? "0x%02x '%s'" % [cp, cp.chr] : "0x%02x" % cp
    {bytes: bytes, comment: comment}
  end

  is_proportional = advances.uniq.length > 1
  first_char_hex = "0x%04x" % first_char
  bpp_label = options[:aa] ? ", 4bpp" : ""
  generator_comment = options[:aa] ? "4bpp anti-aliased, from TTF via FreeType" : "from TTF via FreeType"
  $stderr.puts "#{font_name}, #{glyph_width}x#{glyph_height}, chars 0x%02x-0x%02x, proportional=#{is_proportional}#{bpp_label}" % [first_char, last_char]
end

guard = "DVI_FONT_#{font_name.upcase}_H"
result = HEADER_TEMPLATE.result(binding)

if options[:output]
  File.write(options[:output], result)
  $stderr.puts "Wrote #{options[:output]}"
else
  print result
end
