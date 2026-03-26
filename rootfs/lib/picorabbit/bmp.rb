module PicoRabbit
  class BMP
    attr_reader :width, :height, :data, :mask

    def initialize(width, height, data, mask)
      @width = width
      @height = height
      @data = data
      @mask = mask
    end

    # Load an 8-bit BMP with RGB332 palette.
    # Index 0 is treated as transparent (mask bit = 0).
    def self.load(path)
      raw = File.open(path, "r") { |f| f.read }

      # BITMAPFILEHEADER: offset to pixel data at bytes 10-13
      offset = raw.getbyte(10) | (raw.getbyte(11) << 8) | (raw.getbyte(12) << 16) | (raw.getbyte(13) << 24)

      # BITMAPINFOHEADER: width at 18-21, height at 22-25
      w = raw.getbyte(18) | (raw.getbyte(19) << 8) | (raw.getbyte(20) << 16) | (raw.getbyte(21) << 24)
      h = raw.getbyte(22) | (raw.getbyte(23) << 8) | (raw.getbyte(24) << 16) | (raw.getbyte(25) << 24)

      # BMP rows are padded to 4-byte boundary
      row_bytes = (w + 3) & ~3

      # Build pixel data (top-to-bottom) and 1-bit mask
      pixels = ""
      mask_size = (w * h + 7) / 8
      mask_bytes = Array.new(mask_size, 0)

      h.times do |y|
        # BMP stores bottom row first
        bmp_y = h - 1 - y
        row_offset = offset + bmp_y * row_bytes
        w.times do |x|
          idx = raw.getbyte(row_offset + x)
          pixels << idx.chr
          if idx != 0
            bit_pos = y * w + x
            mask_bytes[bit_pos >> 3] |= (1 << (bit_pos & 7))
          end
        end
      end

      mask_str = mask_bytes.map { |b| b.chr }.join

      BMP.new(w, h, pixels, mask_str)
    end
  end
end
