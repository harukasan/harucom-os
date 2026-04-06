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

options = {
  name: nil,
  output: nil,
  size: 12,
  range: "0x20-0x7f",
  jis: false,
  aa: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} <input.ttf> [options]"
  opts.on("-o FILE", "Output file") { |f| options[:output] = f }
  opts.on("-n NAME", "Font variable name") { |n| options[:name] = n }
  opts.on("-s SIZE", Integer, "Pixel size") { |s| options[:size] = s }
  opts.on("-r RANGE", "Character range (e.g., 0x20-0x7f)") { |r| options[:range] = r }
  opts.on("--jis", "JIS X 0208 mode") { options[:jis] = true }
  opts.on("--aa", "Anti-aliased 4bpp rendering") { options[:aa] = true }
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

  jis_codepoints = uni2jis.keys
  glyph_width, glyph_height, ascender, min_left = scan_dimensions(font, jis_codepoints, options[:size], mono: !options[:aa])
  bitmap_left_value = min_left if options[:aa]
  bytes_per_row = options[:aa] ? (glyph_width + 1) / 2 : (glyph_width + 7) / 8
  bytes_per_glyph = bytes_per_row * glyph_height
  glyph_stride = bytes_per_glyph if options[:aa]

  jis2uni = {}
  uni2jis.each { |cp, idx| jis2uni[idx] = cp }

  rendered = {}
  advances = {}
  jis2uni.each do |idx, cp|
    if options[:aa]
      r = render_glyph_aa(font, cp, glyph_height, glyph_width, ascender: ascender, left_offset: min_left)
      rendered[idx] = r
      # Clamp advance to cover full bitmap extent
      advances[idx] = [r[:advance], r[:bitmap_left] + r[:width] - min_left].max
    else
      r = render_glyph(font, cp, glyph_height, glyph_width, ascender: ascender)
      rendered[idx] = r
      advances[idx] = r[:advance]
    end
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
      # Clamp advance to cover full bitmap extent
      advances << [r[:advance], r[:bitmap_left] + r[:width] - min_left].max
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
