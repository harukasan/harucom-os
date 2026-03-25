class P5
  G = DVI::Graphics

  def initialize
    DVI.set_mode(DVI::GRAPHICS_MODE)
    @fill_color = 0xFF
    @fill_enabled = true
    @stroke_color = 0xFF
    @stroke_enabled = true
    @stroke_weight = 1
    @font = G::FONT_8X8
    @wide_font = nil
    @text_color = 0xFF
  end

  def width
    G::WIDTH
  end

  def height
    G::HEIGHT
  end

  # Screen management

  def background(color)
    G.fill(color)
  end

  def commit
    DVI.wait_vsync
  end

  # State setters

  def fill(color)
    @fill_color = color
    @fill_enabled = true
  end

  def no_fill
    @fill_enabled = false
  end

  def stroke(color)
    @stroke_color = color
    @stroke_enabled = true
  end

  def no_stroke
    @stroke_enabled = false
  end

  def stroke_weight(w)
    @stroke_weight = w
  end

  def text_font(font, wide_font = nil)
    @font = font
    @wide_font = wide_font
  end

  def text_color(color)
    @text_color = color
  end

  # Shape drawing

  def point(x, y)
    G.set_pixel(x, y, @stroke_color) if @stroke_enabled
  end

  def line(x0, y0, x1, y1)
    if @stroke_enabled
      if @stroke_weight > 1
        G.draw_thick_line(x0, y0, x1, y1, @stroke_weight, @stroke_color)
      else
        G.draw_line(x0, y0, x1, y1, @stroke_color)
      end
    end
  end

  def rect(x, y, w, h)
    G.fill_rect(x, y, w, h, @fill_color) if @fill_enabled
    G.draw_rect(x, y, w, h, @stroke_color) if @stroke_enabled
  end

  def circle(cx, cy, r)
    G.fill_circle(cx, cy, r, @fill_color) if @fill_enabled
    G.draw_circle(cx, cy, r, @stroke_color) if @stroke_enabled
  end

  def ellipse(cx, cy, rx, ry)
    G.fill_ellipse(cx, cy, rx, ry, @fill_color) if @fill_enabled
    G.draw_ellipse(cx, cy, rx, ry, @stroke_color) if @stroke_enabled
  end

  def triangle(x0, y0, x1, y1, x2, y2)
    G.fill_triangle(x0, y0, x1, y1, x2, y2, @fill_color) if @fill_enabled
    if @stroke_enabled
      if @stroke_weight > 1
        G.draw_thick_line(x0, y0, x1, y1, @stroke_weight, @stroke_color)
        G.draw_thick_line(x1, y1, x2, y2, @stroke_weight, @stroke_color)
        G.draw_thick_line(x2, y2, x0, y0, @stroke_weight, @stroke_color)
      else
        G.draw_line(x0, y0, x1, y1, @stroke_color)
        G.draw_line(x1, y1, x2, y2, @stroke_color)
        G.draw_line(x2, y2, x0, y0, @stroke_color)
      end
    end
  end

  # Text

  def text(str, x, y)
    if @wide_font
      G.draw_text(x, y, str, @text_color, @font, @wide_font)
    else
      G.draw_text(x, y, str, @text_color, @font)
    end
  end

  # Image

  def image(data, x, y, w, h)
    G.draw_image(data, x, y, w, h)
  end

  def image_masked(data, mask, x, y, w, h)
    G.draw_image_masked(data, mask, x, y, w, h)
  end

  # Pixel access

  def get_pixel(x, y)
    G.get_pixel(x, y)
  end

  def set_pixel(x, y, color)
    G.set_pixel(x, y, color)
  end

  # Color utility

  def color(r, g, b)
    (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)
  end
end
