module PicoRabbit
  class BMP
    attr_reader :width, :height, :data

    def initialize(width, height, data)
      @width = width
      @height = height
      @data = data
      @mask = nil
    end

    # Lazily generate transparency mask on first access.
    # Images drawn with p5.image() skip mask generation entirely.
    def mask
      @mask ||= build_mask
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

      # Build pixel data: collect rows then join once to avoid repeated reallocation
      rows = Array.new(h)
      (h - 1).downto(0) do |bmp_y|
        rows[h - 1 - bmp_y] = raw.byteslice(offset + bmp_y * row_bytes, w)
      end

      BMP.new(w, h, rows.join)
    end

    private

    def build_mask
      w = @width
      h = @height
      pixels = @data
      mask_size = (w * h + 7) / 8

      unless pixels.include?("\x00")
        return "\xff" * mask_size
      end

      # Process row by row: skip fully opaque rows
      mask_bytes = Array.new(mask_size, 0xFF)
      h.times do |y|
        row_start = y * w
        row = pixels.byteslice(row_start, w)
        next unless row.include?("\x00")
        w.times do |x|
          if pixels.getbyte(row_start + x) == 0
            bit_pos = row_start + x
            mask_bytes[bit_pos >> 3] &= ~(1 << (bit_pos & 7))
          end
        end
      end
      mask_str = ""
      mask_bytes.each { |b| mask_str << b.chr }
      mask_str
    end
  end
end
