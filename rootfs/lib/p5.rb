class P5
  G = DVI::Graphics

  # Cap push_matrix depth so runaway code (missing pop_matrix in a loop)
  # cannot exhaust the mruby heap. Normal nesting rarely exceeds 5.
  MATRIX_STACK_MAX = 32

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
    @text_align_h = :left
    @text_align_v = :top
    @text_leading = 0
    @matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
    @matrix_stack = []
  end

  def width
    G.width
  end

  def height
    G.height
  end

  # Screen management

  def background(color)
    G.fill(color)
  end

  def commit
    G.commit
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
    w = 0 if w < 0
    @stroke_weight = w
  end

  # Blend mode constants
  REPLACE  = G::BLEND_REPLACE
  ADD      = G::BLEND_ADD
  SUBTRACT = G::BLEND_SUBTRACT
  MULTIPLY = G::BLEND_MULTIPLY
  SCREEN   = G::BLEND_SCREEN

  def blend_mode(mode)
    G.set_blend_mode(mode)
  end

  def alpha(value)
    value = 0 if value < 0
    value = 255 if value > 255
    G.set_blend_mode(G::BLEND_ALPHA)
    G.set_alpha(value)
  end

  def text_font(font, wide_font = nil)
    @font = font
    @wide_font = wide_font
  end

  def text_color(color)
    @text_color = color
  end

  # Text alignment: horizontal (:left, :center, :right),
  # vertical (:top, :center, :bottom)
  def text_align(horizontal, vertical = :top)
    @text_align_h = horizontal
    @text_align_v = vertical
  end

  # Extra line spacing in pixels (added to font glyph height)
  def text_leading(pixels)
    @text_leading = pixels
  end

  # Compute the pixel width of a string with the current font
  def text_width(str)
    if @wide_font
      G.text_width(str, @font, @wide_font)
    else
      G.text_width(str, @font)
    end
  end

  # Coordinate transforms
  #
  # Transform state is a 2x3 affine matrix [a, b, c, d, tx, ty]:
  #   x' = a*x + b*y + tx
  #   y' = c*x + d*y + ty
  #
  # Drawing functions check translate_only? for a fast path (integer add)
  # and fall back to full matrix transform for rotation/scale.

  def translate(tx, ty)
    @matrix = matrix_multiply(@matrix, [1.0, 0.0, 0.0, 1.0, tx.to_f, ty.to_f])
  end

  def rotate(angle)
    c = Math.cos(angle)
    s = Math.sin(angle)
    @matrix = matrix_multiply(@matrix, [c, -s, s, c, 0.0, 0.0])
  end

  def scale(sx, sy = sx)
    @matrix = matrix_multiply(@matrix, [sx.to_f, 0.0, 0.0, sy.to_f, 0.0, 0.0])
  end

  def push_matrix
    if @matrix_stack.length >= MATRIX_STACK_MAX
      raise "P5: matrix stack overflow (max depth #{MATRIX_STACK_MAX})"
    end
    @matrix_stack.push(@matrix.dup)
  end

  def pop_matrix
    @matrix = @matrix_stack.pop if @matrix_stack.length > 0
  end

  def reset_matrix
    @matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
  end

  # Shape drawing

  def point(x, y)
    return unless @stroke_enabled
    px, py = transform(x, y)
    G.set_pixel(px, py, @stroke_color)
  end

  def line(x0, y0, x1, y1)
    return unless @stroke_enabled
    ax, ay = transform(x0, y0)
    bx, by = transform(x1, y1)
    if @stroke_weight > 1
      G.draw_thick_line(ax, ay, bx, by, @stroke_weight, @stroke_color)
    else
      G.draw_line(ax, ay, bx, by, @stroke_color)
    end
  end

  def rect(x, y, w, h)
    if translate_only?
      tx = @matrix[4].round
      ty = @matrix[5].round
      G.fill_rect(x + tx, y + ty, w, h, @fill_color) if @fill_enabled
      G.draw_rect(x + tx, y + ty, w, h, @stroke_color) if @stroke_enabled
    else
      x0, y0 = transform(x, y)
      x1, y1 = transform(x + w, y)
      x2, y2 = transform(x + w, y + h)
      x3, y3 = transform(x, y + h)
      if @fill_enabled
        G.fill_triangle(x0, y0, x1, y1, x2, y2, @fill_color)
        G.fill_triangle(x0, y0, x2, y2, x3, y3, @fill_color)
      end
      if @stroke_enabled
        draw_edge(x0, y0, x1, y1)
        draw_edge(x1, y1, x2, y2)
        draw_edge(x2, y2, x3, y3)
        draw_edge(x3, y3, x0, y0)
      end
    end
  end

  def circle(cx, cy, r)
    tcx, tcy = transform(cx, cy)
    if translate_only?
      G.fill_circle(tcx, tcy, r, @fill_color) if @fill_enabled
      G.draw_circle(tcx, tcy, r, @stroke_color) if @stroke_enabled
    else
      sx = Math.sqrt(@matrix[0] * @matrix[0] + @matrix[2] * @matrix[2])
      sy = Math.sqrt(@matrix[1] * @matrix[1] + @matrix[3] * @matrix[3])
      rx = (r * sx).round
      ry = (r * sy).round
      G.fill_ellipse(tcx, tcy, rx, ry, @fill_color) if @fill_enabled
      G.draw_ellipse(tcx, tcy, rx, ry, @stroke_color) if @stroke_enabled
    end
  end

  def ellipse(cx, cy, rx, ry)
    tcx, tcy = transform(cx, cy)
    if translate_only?
      G.fill_ellipse(tcx, tcy, rx, ry, @fill_color) if @fill_enabled
      G.draw_ellipse(tcx, tcy, rx, ry, @stroke_color) if @stroke_enabled
    else
      sx = Math.sqrt(@matrix[0] * @matrix[0] + @matrix[2] * @matrix[2])
      sy = Math.sqrt(@matrix[1] * @matrix[1] + @matrix[3] * @matrix[3])
      trx = (rx * sx).round
      try_ = (ry * sy).round
      G.fill_ellipse(tcx, tcy, trx, try_, @fill_color) if @fill_enabled
      G.draw_ellipse(tcx, tcy, trx, try_, @stroke_color) if @stroke_enabled
    end
  end

  def triangle(x0, y0, x1, y1, x2, y2)
    ax, ay = transform(x0, y0)
    bx, by = transform(x1, y1)
    cx, cy = transform(x2, y2)
    G.fill_triangle(ax, ay, bx, by, cx, cy, @fill_color) if @fill_enabled
    if @stroke_enabled
      draw_edge(ax, ay, bx, by)
      draw_edge(bx, by, cx, cy)
      draw_edge(cx, cy, ax, ay)
    end
  end

  # Arc (pie slice). Angles in radians (0 = right, PI/2 = down).
  # C layer renders as a triangle fan from center using hardware sinf/cosf.
  def arc(cx, cy, r, start_angle, stop_angle)
    tcx, tcy = transform(cx, cy)
    G.fill_arc(tcx, tcy, r, start_angle, stop_angle, @fill_color) if @fill_enabled
    G.draw_arc(tcx, tcy, r, start_angle, stop_angle, @stroke_color) if @stroke_enabled
  end

  # Cubic bezier curve from (x1,y1) to (x4,y4) with control points (x2,y2) and (x3,y3).
  # Rendered as a series of line segments.
  def bezier(x1, y1, x2, y2, x3, y3, x4, y4)
    return unless @stroke_enabled
    segments = 20
    px, py = transform(x1, y1)
    segments.times do |i|
      t = (i + 1).to_f / segments
      t2 = t * t
      t3 = t2 * t
      mt = 1.0 - t
      mt2 = mt * mt
      mt3 = mt2 * mt
      nx = (mt3 * x1 + 3 * mt2 * t * x2 + 3 * mt * t2 * x3 + t3 * x4)
      ny = (mt3 * y1 + 3 * mt2 * t * y2 + 3 * mt * t2 * y3 + t3 * y4)
      qx, qy = transform(nx, ny)
      draw_edge(px, py, qx, qy)
      px = qx
      py = qy
    end
  end

  # Catmull-Rom spline through (x2,y2) to (x3,y3), shaped by (x1,y1) and (x4,y4).
  # Rendered as a series of line segments.
  def curve(x1, y1, x2, y2, x3, y3, x4, y4)
    return unless @stroke_enabled
    segments = 20
    px, py = transform(x2, y2)
    segments.times do |i|
      t = (i + 1).to_f / segments
      t2 = t * t
      t3 = t2 * t
      # Catmull-Rom basis matrix coefficients
      nx = 0.5 * ((2*x2) + (-x1+x3)*t + (2*x1-5*x2+4*x3-x4)*t2 + (-x1+3*x2-3*x3+x4)*t3)
      ny = 0.5 * ((2*y2) + (-y1+y3)*t + (2*y1-5*y2+4*y3-y4)*t2 + (-y1+3*y2-3*y3+y4)*t3)
      qx, qy = transform(nx, ny)
      draw_edge(px, py, qx, qy)
      px = qx
      py = qy
    end
  end

  # Text with alignment and affine transform support.

  def text(str, x, y)
    # Apply horizontal alignment in user space
    if @text_align_h == :center
      x -= text_width(str) / 2
    elsif @text_align_h == :right
      x -= text_width(str)
    end

    # Apply vertical alignment in user space
    if @text_align_v == :center
      y -= font_height / 2
    elsif @text_align_v == :bottom
      y -= font_height
    end

    if translate_only?
      tx, ty = transform(x, y)
      if @wide_font
        G.draw_text(tx, ty, str, @text_color, @font, @wide_font)
      else
        G.draw_text(tx, ty, str, @text_color, @font)
      end
    else
      m = @matrix
      wide_id = @wide_font ? @wide_font : -1
      G.draw_text_affine(str, @text_color, @font, wide_id, x, y,
                         m[0], m[1], m[2], m[3], m[4], m[5])
    end
  end

  # Image

  def image(data, x, y, w, h)
    if translate_only?
      tx, ty = transform(x, y)
      G.draw_image(data, tx, ty, w, h)
    else
      m = @matrix
      G.draw_image_affine(data, w, h, x, y,
                          m[0], m[1], m[2], m[3], m[4], m[5])
    end
  end

  def image_masked(data, mask, x, y, w, h)
    if translate_only?
      tx, ty = transform(x, y)
      G.draw_image_masked(data, mask, tx, ty, w, h)
    else
      m = @matrix
      G.draw_image_masked_affine(data, mask, w, h, x, y,
                                 m[0], m[1], m[2], m[3], m[4], m[5])
    end
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

  private

  def font_height
    G.font_height(@font)
  end

  def transform(x, y)
    m = @matrix
    [(m[0] * x + m[1] * y + m[4]).round,
     (m[2] * x + m[3] * y + m[5]).round]
  end

  def translate_only?
    m = @matrix
    m[0] == 1.0 && m[1] == 0.0 && m[2] == 0.0 && m[3] == 1.0
  end

  def matrix_multiply(a, b)
    [a[0]*b[0] + a[1]*b[2], a[0]*b[1] + a[1]*b[3],
     a[2]*b[0] + a[3]*b[2], a[2]*b[1] + a[3]*b[3],
     a[0]*b[4] + a[1]*b[5] + a[4], a[2]*b[4] + a[3]*b[5] + a[5]]
  end

  def draw_edge(x0, y0, x1, y1)
    if @stroke_weight > 1
      G.draw_thick_line(x0, y0, x1, y1, @stroke_weight, @stroke_color)
    else
      G.draw_line(x0, y0, x1, y1, @stroke_color)
    end
  end
end
