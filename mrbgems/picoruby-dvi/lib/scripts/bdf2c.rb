#!/usr/bin/env ruby
# frozen_string_literal: true

# BDF to C header converter for dvi_font_t.
# Generates a C header file from one or more BDF bitmap fonts.
#
# Usage: ruby bdf2c.rb <input.bdf> [options]
#   -o FILE     Output file (default: stdout)
#   -n NAME     Font variable name (default: derived from filename)
#   -r RANGE    Character range as "first-last" (default: 0x20-0x7f)
#   --jis       JIS X 0208 mode: use linear ku-ten indexing
#   --bold FILE Bold BDF file to interleave with regular
#              (generates interleaved regular+bold bitmap)

require "optparse"
require "erb"

class BDFGlyph
  attr_accessor :encoding, :dwidth, :width, :height, :x_offset, :y_offset, :bitmap_rows

  def initialize
    @dwidth = 0
    @bitmap_rows = []
  end
end

class BDFParser
  attr_reader :glyphs, :fbb_width, :fbb_height, :fbb_x_offset, :fbb_y_offset

  def initialize(io)
    @glyphs = {}
    @fbb_width = 0
    @fbb_height = 0
    @fbb_x_offset = 0
    @fbb_y_offset = 0
    parse(io)
  end

  private

  def parse(io)
    current_glyph = nil
    in_bitmap = false

    io.each_line do |line|
      line = line.strip
      tokens = line.split

      case tokens[0]
      when "FONTBOUNDINGBOX"
        @fbb_width = tokens[1].to_i
        @fbb_height = tokens[2].to_i
        @fbb_x_offset = tokens[3].to_i
        @fbb_y_offset = tokens[4].to_i
      when "STARTCHAR"
        current_glyph = BDFGlyph.new
      when "ENCODING"
        current_glyph.encoding = tokens[1].to_i if current_glyph
      when "DWIDTH"
        current_glyph.dwidth = tokens[1].to_i if current_glyph
      when "BBX"
        if current_glyph
          current_glyph.width = tokens[1].to_i
          current_glyph.height = tokens[2].to_i
          current_glyph.x_offset = tokens[3].to_i
          current_glyph.y_offset = tokens[4].to_i
        end
      when "BITMAP"
        in_bitmap = true if current_glyph
      when "ENDCHAR"
        if current_glyph
          @glyphs[current_glyph.encoding] = current_glyph
          current_glyph = nil
          in_bitmap = false
        end
      else
        if in_bitmap && current_glyph
          current_glyph.bitmap_rows << tokens[0].to_i(16)
        end
      end
    end
  end
end

def render_glyph(glyph, fbb_width, fbb_height, fbb_x_offset, fbb_y_offset)
  bytes_per_row = (fbb_width + 7) / 8
  src_bytes_per_row = (glyph.width + 7) / 8
  rows = Array.new(fbb_height, 0)

  # Place glyph bitmap into the bounding box, aligning from the top.
  # BDF y_offset is relative to the baseline; fbb_y_offset is the font's
  # global descent (typically negative).
  y_start = fbb_height - (glyph.y_offset - fbb_y_offset) - glyph.height

  # BDF bitmaps are MSB-aligned within their byte storage.
  # Shift to position the glyph's x_offset within the font bounding box.
  shift = (bytes_per_row - src_bytes_per_row) * 8 - (glyph.x_offset - fbb_x_offset)

  glyph.bitmap_rows.each_with_index do |row_bits, i|
    y = y_start + i
    next if y < 0 || y >= fbb_height

    if shift > 0
      row_bits <<= shift
    elsif shift < 0
      row_bits >>= -shift
    end

    # Mask to bounding box width
    mask = ((1 << fbb_width) - 1) << (bytes_per_row * 8 - fbb_width)
    rows[y] = row_bits & mask
  end

  # Pack into bytes
  rows.flat_map do |row|
    bytes_per_row.times.map do |b|
      (row >> (8 * (bytes_per_row - 1 - b))) & 0xFF
    end
  end
end

def render_glyph_bytes(bdf, code_or_glyph, bytes_per_glyph)
  glyph = code_or_glyph.is_a?(BDFGlyph) ? code_or_glyph : bdf.glyphs[code_or_glyph]
  if glyph
    render_glyph(glyph, bdf.fbb_width, bdf.fbb_height, bdf.fbb_x_offset, bdf.fbb_y_offset)
  else
    Array.new(bytes_per_glyph, 0)
  end
end

def glyph_advance_width(bdf, code)
  glyph = bdf.glyphs[code]
  return bdf.fbb_width unless glyph
  glyph.dwidth > 0 ? glyph.dwidth : glyph.x_offset + glyph.width
end

HEADER_TEMPLATE = ERB.new(<<~'TEMPLATE', trim_mode: "-")
<%= header_comment -%>
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

<% font_structs.each_with_index do |s, i| -%>
<% if i > 0 %>
<% end -%>
<%= s[:comment] ? "#{s[:comment]}\n" : "" -%>
static const dvi_font_t font_<%= s[:name] %> = {
    .glyph_width  = <%= glyph_width %>,
    .glyph_height = <%= glyph_height %>,
    .first_char   = <%= s[:first_char] %>,
    .num_chars    = <%= num_chars %>,
    .bitmap       = font_<%= font_name %>_bitmap,
<% if is_proportional -%>
    .widths       = font_<%= font_name %>_widths,
<% end -%>
<% if s[:glyph_stride] -%>
    .glyph_stride = <%= s[:glyph_stride] %>,
<% end -%>
};
<% end -%>

#endif
TEMPLATE

def format_char_comment(code)
  if code >= 0x20 && code <= 0x7E
    "0x%02x '%s'" % [code, code.chr]
  else
    "0x%02x" % code
  end
end

def format_jis_comment(idx)
  ku = idx / 94 + 1
  ten = idx % 94 + 1
  "idx=%d ku=%d ten=%d" % [idx, ku, ten]
end

# Build Unicode codepoint -> JIS linear index mapping via EUC-JP.
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

# Build JIS glyph map from JIS-encoded BDF.
# JIS encoding: (ku+0x20)*256 + (ten+0x20), ku/ten are 1-indexed (1-94).
# Linear index: (ku-1)*94 + (ten-1), range 0..8835 (94*94-1).
def build_jis_glyph_map(bdf)
  jis_glyphs = {}
  bdf.glyphs.each do |enc, glyph|
    ku = (enc >> 8) - 0x20
    ten = (enc & 0xFF) - 0x20
    next unless ku >= 1 && ku <= 94 && ten >= 1 && ten <= 94
    linear = (ku - 1) * 94 + (ten - 1)
    jis_glyphs[linear] = glyph
  end
  jis_glyphs
end

# Build JIS glyph map from a Unicode-encoded BDF (e.g. otf2bdf output).
def build_jis_glyph_map_from_unicode(bdf)
  uni2jis = build_unicode_to_jis_map
  jis_glyphs = {}
  bdf.glyphs.each do |enc, glyph|
    linear = uni2jis[enc]
    next unless linear
    jis_glyphs[linear] = glyph
  end
  jis_glyphs
end

# main

options = {
  name: nil,
  output: nil,
  range: "0x20-0x7f",
  jis: false,
  bold: nil,
  jis_from_unicode: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} <input.bdf> [options]"
  opts.on("-o FILE", "Output file") { |f| options[:output] = f }
  opts.on("-n NAME", "Font variable name") { |n| options[:name] = n }
  opts.on("-r RANGE", "Character range (e.g., 0x20-0x7f)") { |r| options[:range] = r }
  opts.on("--jis", "JIS X 0208 mode: use linear ku-ten indexing") { options[:jis] = true }
  opts.on("--jis-from-unicode", "JIS mode with Unicode-encoded BDF (convert via EUC-JP)") { options[:jis_from_unicode] = true }
  opts.on("--bold FILE", "Bold BDF file to interleave with regular") { |f| options[:bold] = f }
end.parse!

input_path = ARGV[0]
unless input_path
  $stderr.puts "Error: no input BDF file specified"
  exit 1
end

font_name = options[:name] || File.basename(input_path, ".bdf").gsub(/[^a-zA-Z0-9_]/, "_")

bdf = File.open(input_path) { |f| BDFParser.new(f) }

# Verify monospace
widths = bdf.glyphs.values.map(&:width).uniq
if widths.length > 1
  $stderr.puts "Warning: font has multiple glyph widths (#{widths.join(', ')}), using bounding box width #{bdf.fbb_width}"
end

bold_bdf = nil
if options[:bold]
  bold_bdf = File.open(options[:bold]) { |f| BDFParser.new(f) }
  bold_widths = bold_bdf.glyphs.values.map(&:width).uniq
  if bold_widths.length > 1
    $stderr.puts "Warning: bold font has multiple glyph widths (#{bold_widths.join(', ')}), using bounding box width #{bold_bdf.fbb_width}"
  end
end

bytes_per_row = (bdf.fbb_width + 7) / 8
bytes_per_glyph = bytes_per_row * bdf.fbb_height
glyph_width = bdf.fbb_width
glyph_height = bdf.fbb_height

if bold_bdf
  unless bdf.fbb_width == bold_bdf.fbb_width && bdf.fbb_height == bold_bdf.fbb_height
    raise "Font dimension mismatch: regular #{bdf.fbb_width}x#{bdf.fbb_height} " \
          "vs bold #{bold_bdf.fbb_width}x#{bold_bdf.fbb_height}"
  end

  if options[:jis]
    # JIS interleaved regular + bold
    num_chars = 94 * 94
    reg_jis = build_jis_glyph_map(bdf)
    bold_jis = build_jis_glyph_map(bold_bdf)
    $stderr.puts "JIS interleaved mode: #{reg_jis.size} regular, #{bold_jis.size} bold / #{num_chars} slots"

    glyphs = num_chars.times.flat_map do |idx|
      comment = format_jis_comment(idx)
      [
        {bytes: render_glyph_bytes(bdf, reg_jis[idx], bytes_per_glyph), comment: "#{comment} regular"},
        {bytes: render_glyph_bytes(bold_bdf, bold_jis[idx], bytes_per_glyph), comment: "#{comment} bold"}
      ]
    end

    is_proportional = false
    advances = []
    wide_name = font_name.sub(/_combined$/, "_wide")
    font_structs = [
      {name: font_name, first_char: "0"},
      {name: wide_name, first_char: "0", glyph_stride: bytes_per_glyph * 2,
       comment: "// Graphics mode: regular glyphs only (stride skips bold)."}
    ]

    total = num_chars * bytes_per_glyph * 2
    header_comment = <<~COMMENT
      // Generated by bdf2c.rb (JIS X 0208, interleaved regular + bold)
      // Linear index = (ku-1)*94 + (ten-1), ku/ten 1-indexed
      // Layout: [ch0_regular(#{bytes_per_glyph}B), ch0_bold(#{bytes_per_glyph}B), ...]
      // Stride per glyph pair: #{bytes_per_glyph * 2} bytes
      // Bold offset: +#{bytes_per_glyph} bytes from regular
    COMMENT
    description = "#{font_name}, #{glyph_width}x#{glyph_height}, JIS X 0208 interleaved, " \
                  "stride=#{bytes_per_glyph * 2}, total=#{total} bytes (#{total / 1024.0}KB)"
  else
    # ASCII/Latin interleaved regular + bold
    range_parts = options[:range].split("-")
    first_char = Integer(range_parts[0])
    last_char = Integer(range_parts[1])
    num_chars = last_char - first_char + 1

    glyphs = (first_char..last_char).flat_map do |code|
      comment = format_char_comment(code)
      [
        {bytes: render_glyph_bytes(bdf, code, bytes_per_glyph), comment: "#{comment} regular"},
        {bytes: render_glyph_bytes(bold_bdf, code, bytes_per_glyph), comment: "#{comment} bold"}
      ]
    end

    is_proportional = false
    advances = []
    font_structs = [{name: font_name, first_char: "0x%04x" % first_char}]

    header_comment = <<~COMMENT
      // Generated by bdf2c.rb (interleaved regular + bold)
      // Layout: [ch0_regular(#{bytes_per_glyph}B), ch0_bold(#{bytes_per_glyph}B), ...]
      // Stride per glyph pair: #{bytes_per_glyph * 2} bytes
      // Bold offset: +#{bytes_per_glyph} bytes from regular
    COMMENT
    description = "#{font_name}, #{glyph_width}x#{glyph_height}, interleaved, " \
                  "chars 0x%02x-0x%02x, stride=#{bytes_per_glyph * 2}" % [first_char, last_char]
  end

elsif options[:jis_from_unicode]
  # JIS from Unicode-encoded BDF
  num_chars = 94 * 94
  jis_glyphs = build_jis_glyph_map_from_unicode(bdf)
  $stderr.puts "JIS from Unicode mode: #{jis_glyphs.size}/#{num_chars} slots populated"

  glyphs = num_chars.times.map do |idx|
    {bytes: render_glyph_bytes(bdf, jis_glyphs[idx], bytes_per_glyph), comment: format_jis_comment(idx)}
  end

  width_values = jis_glyphs.values.map { |g| g.dwidth > 0 ? g.dwidth : glyph_width }
  is_proportional = width_values.uniq.length > 1
  advances = is_proportional ? num_chars.times.map { |idx|
    g = jis_glyphs[idx]
    g ? (g.dwidth > 0 ? g.dwidth : glyph_width) : glyph_width
  } : []

  font_structs = [{name: font_name, first_char: "0"}]
  header_comment = <<~COMMENT
    // Generated by bdf2c.rb (JIS X 0208, converted from Unicode-encoded BDF)
    // Linear index = (ku-1)*94 + (ten-1), ku/ten 1-indexed
  COMMENT
  description = "#{font_name}, #{glyph_width}x#{glyph_height}, JIS from Unicode, #{bdf.glyphs.size} glyphs"

elsif options[:jis]
  # JIS from JIS-encoded BDF
  num_chars = 94 * 94
  jis_glyphs = build_jis_glyph_map(bdf)
  $stderr.puts "JIS mode: #{jis_glyphs.size}/#{num_chars} slots populated"

  glyphs = num_chars.times.map do |idx|
    {bytes: render_glyph_bytes(bdf, jis_glyphs[idx], bytes_per_glyph), comment: format_jis_comment(idx)}
  end

  is_proportional = false
  advances = []
  font_structs = [{name: font_name, first_char: "0"}]

  header_comment = <<~COMMENT
    // Generated by bdf2c.rb (JIS X 0208 linear index mode)
    // Linear index = (ku-1)*94 + (ten-1), ku/ten 1-indexed
    //
    // To convert a JIS code to linear index:
    //   int ku  = (jis_code >> 8) - 0x20;
    //   int ten = (jis_code & 0xFF) - 0x20;
    //   int idx = (ku - 1) * 94 + (ten - 1);
  COMMENT
  description = "#{font_name}, #{glyph_width}x#{glyph_height}, JIS X 0208, #{bdf.glyphs.size} glyphs"

else
  # ASCII/Latin mode
  range_parts = options[:range].split("-")
  first_char = Integer(range_parts[0])
  last_char = Integer(range_parts[1])
  num_chars = last_char - first_char + 1

  glyphs = (first_char..last_char).map do |code|
    {bytes: render_glyph_bytes(bdf, code, bytes_per_glyph), comment: format_char_comment(code)}
  end

  advances = (first_char..last_char).map { |c| glyph_advance_width(bdf, c) }
  is_proportional = advances.uniq.length > 1
  advances = [] unless is_proportional

  font_structs = [{name: font_name, first_char: "0x%04x" % first_char}]
  header_comment = "// Generated by bdf2c.rb\n"
  description = "#{font_name}, #{glyph_width}x#{glyph_height}, chars 0x%02x-0x%02x" % [first_char, last_char]
end

guard = "DVI_FONT_#{font_name.upcase}_H"
result = HEADER_TEMPLATE.result(binding)

if options[:output]
  File.write(options[:output], result)
  $stderr.puts "Wrote #{options[:output]} (#{description})"
else
  print result
end
