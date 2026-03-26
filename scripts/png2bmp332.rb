#!/usr/bin/env ruby
# Convert a PNG image to an 8-bit BMP with an RGB332 palette.
#
# Transparent pixels (alpha < 128) are mapped to palette index 0,
# which is set to magenta (0xFF, 0x00, 0xFF) as the mask color.
#
# Usage: ruby scripts/png2bmp332.rb input.png -o output.bmp

require "chunky_png"

input_path = nil
output_path = nil

i = 0
while i < ARGV.length
  case ARGV[i]
  when "-o"
    i += 1
    output_path = ARGV[i]
  else
    input_path = ARGV[i]
  end
  i += 1
end

unless input_path
  $stderr.puts "Usage: #{$0} input.png -o output.bmp"
  exit 1
end

output_path ||= input_path.sub(/\.png$/i, ".bmp")

img = ChunkyPNG::Image.from_file(input_path)
width = img.width
height = img.height

# Build RGB332 palette (256 entries).
# Index 0 is reserved as the transparent mask color (magenta).
palette = Array.new(256 * 4, 0)
# Index 0: magenta (B, G, R, 0x00 in BMP RGBQUAD order)
palette[0] = 0xFF  # B
palette[1] = 0x00  # G
palette[2] = 0xFF  # R
palette[3] = 0x00  # reserved

(1..255).each do |idx|
  r3 = (idx >> 5) & 0x07
  g3 = (idx >> 2) & 0x07
  b2 = idx & 0x03
  palette[idx * 4 + 0] = (b2 * 255 / 3.0).round  # B
  palette[idx * 4 + 1] = (g3 * 255 / 7.0).round  # G
  palette[idx * 4 + 2] = (r3 * 255 / 7.0).round  # R
  palette[idx * 4 + 3] = 0x00
end

# Convert pixels to RGB332 indices.
# BMP stores rows bottom-to-top, each row padded to 4-byte boundary.
row_bytes = (width + 3) & ~3
pixel_data = Array.new(row_bytes * height, 0)

(0...height).each do |y|
  # BMP row order: bottom row first
  bmp_y = height - 1 - y
  (0...width).each do |x|
    rgba = img[x, y]
    a = ChunkyPNG::Color.a(rgba)
    if a < 128
      # Transparent -> index 0 (mask color)
      pixel_data[bmp_y * row_bytes + x] = 0
    else
      r = ChunkyPNG::Color.r(rgba)
      g = ChunkyPNG::Color.g(rgba)
      b = ChunkyPNG::Color.b(rgba)
      idx = (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)
      # Avoid index 0 for opaque pixels (remap black to index 0x24)
      idx = 0x24 if idx == 0
      pixel_data[bmp_y * row_bytes + x] = idx
    end
  end
end

# Write BMP file
palette_size = 256 * 4
header_size = 14 + 40 + palette_size
file_size = header_size + pixel_data.length

File.open(output_path, "wb") do |f|
  # BITMAPFILEHEADER (14 bytes)
  f.write("BM")
  f.write([file_size].pack("V"))
  f.write([0].pack("V"))          # reserved
  f.write([header_size].pack("V"))

  # BITMAPINFOHEADER (40 bytes)
  f.write([40].pack("V"))         # header size
  f.write([width].pack("V"))
  f.write([height].pack("V"))
  f.write([1].pack("v"))          # planes
  f.write([8].pack("v"))          # bits per pixel
  f.write([0].pack("V"))          # compression (none)
  f.write([pixel_data.length].pack("V"))
  f.write([0].pack("V"))          # X pixels per meter
  f.write([0].pack("V"))          # Y pixels per meter
  f.write([256].pack("V"))        # colors used
  f.write([0].pack("V"))          # important colors

  # Palette
  f.write(palette.pack("C*"))

  # Pixel data
  f.write(pixel_data.pack("C*"))
end

$stderr.puts "#{output_path}: #{width}x#{height}, #{file_size} bytes"
