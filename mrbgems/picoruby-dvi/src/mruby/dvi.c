#include <string.h>

#include <mruby.h>
#include <mruby/presym.h>
#include <mruby/data.h>
#include <mruby/class.h>

#include "dvi.h"
#include "dvi_graphics_draw.h"

/*
 * DVI::Text::Line - opaque container for one row of VRAM cells.
 * Used by read_line/write_line for scrollback buffer support.
 */
struct dvi_text_line {
  dvi_text_cell_t cells[DVI_TEXT_MAX_COLS];
};

static void
dvi_text_line_free(mrb_state *mrb, void *ptr)
{
  mrb_free(mrb, ptr);
}

static const mrb_data_type dvi_text_line_type = {"DVI::Text::Line", dvi_text_line_free};

static struct RClass *class_Line;

/*
 * DVI.set_mode(mode)
 */
static mrb_value
mrb_dvi_set_mode(mrb_state *mrb, mrb_value klass)
{
  mrb_int mode;
  mrb_get_args(mrb, "i", &mode);
  dvi_set_mode((dvi_mode_t)mode);
  return mrb_nil_value();
}

/*
 * DVI.wait_vsync
 */
static mrb_value
mrb_dvi_wait_vsync(mrb_state *mrb, mrb_value klass)
{
  dvi_wait_vsync();
  return mrb_nil_value();
}

/*
 * DVI.frame_count
 */
static mrb_value
mrb_dvi_frame_count(mrb_state *mrb, mrb_value klass)
{
  return mrb_fixnum_value(dvi_get_frame_count());
}

/*
 * DVI::Graphics.width
 */
static mrb_value
mrb_dvi_graphics_width(mrb_state *mrb, mrb_value klass)
{
  return mrb_fixnum_value(dvi_graphics_get_width());
}

/*
 * DVI::Graphics.height
 */
static mrb_value
mrb_dvi_graphics_height(mrb_state *mrb, mrb_value klass)
{
  return mrb_fixnum_value(dvi_graphics_get_height());
}

/*
 * DVI::Graphics.set_resolution(width, height)
 */
static mrb_value
mrb_dvi_set_resolution(mrb_state *mrb, mrb_value klass)
{
  mrb_int w, h;
  mrb_get_args(mrb, "ii", &w, &h);
  if (w == 640 && h == 480)
    dvi_set_graphics_scale(1);
  else if (w == 320 && h == 240)
    dvi_set_graphics_scale(2);
  else
    mrb_raise(mrb, E_ARGUMENT_ERROR, "resolution must be 640x480 or 320x240");
  return mrb_nil_value();
}

/*
 * DVI::Graphics.commit
 */
static mrb_value
mrb_dvi_graphics_commit(mrb_state *mrb, mrb_value klass)
{
  dvi_graphics_commit();
  return mrb_nil_value();
}

/*
 * DVI::Graphics.set_blend_mode(mode)
 */
static mrb_value
mrb_dvi_set_blend_mode(mrb_state *mrb, mrb_value klass)
{
  mrb_int mode;
  mrb_get_args(mrb, "i", &mode);
  dvi_graphics_set_blend_mode((enum dvi_graphics_blend_mode)mode);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.set_alpha(alpha)
 */
static mrb_value
mrb_dvi_set_alpha(mrb_state *mrb, mrb_value klass)
{
  mrb_int alpha;
  mrb_get_args(mrb, "i", &alpha);
  dvi_graphics_set_alpha((uint8_t)alpha);
  return mrb_nil_value();
}

/*
 * DVI.set_pixel(x, y, color)
 */
static mrb_value
mrb_dvi_set_pixel(mrb_state *mrb, mrb_value klass)
{
  mrb_int x, y, color;
  mrb_get_args(mrb, "iii", &x, &y, &color);
  if (x < 0 || x >= dvi_graphics_get_width() || y < 0 || y >= dvi_graphics_get_height())
    return mrb_nil_value();
  dvi_get_framebuffer()[y * dvi_graphics_get_width() + x] = (uint8_t)color;
  return mrb_nil_value();
}

/*
 * DVI.get_pixel(x, y)
 */
static mrb_value
mrb_dvi_get_pixel(mrb_state *mrb, mrb_value klass)
{
  mrb_int x, y;
  mrb_get_args(mrb, "ii", &x, &y);
  if (x < 0 || x >= dvi_graphics_get_width() || y < 0 || y >= dvi_graphics_get_height())
    return mrb_fixnum_value(0);
  return mrb_fixnum_value(dvi_get_framebuffer()[y * dvi_graphics_get_width() + x]);
}

/*
 * DVI.fill(color)
 */
static mrb_value
mrb_dvi_fill(mrb_state *mrb, mrb_value klass)
{
  mrb_int color;
  mrb_get_args(mrb, "i", &color);
  memset(dvi_get_framebuffer(), (uint8_t)color,
         dvi_graphics_get_width() * dvi_graphics_get_height());
  return mrb_nil_value();
}

/*
 * DVI.fill_rect(x, y, w, h, color)
 */
static mrb_value
mrb_dvi_fill_rect(mrb_state *mrb, mrb_value klass)
{
  mrb_int x, y, w, h, color;
  mrb_get_args(mrb, "iiiii", &x, &y, &w, &h, &color);
  dvi_graphics_fill_rect(dvi_get_framebuffer(), dvi_graphics_get_width(), dvi_graphics_get_height(),
                         x, y, w, h, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_rect(x, y, w, h, color)
 */
static mrb_value
mrb_dvi_draw_rect(mrb_state *mrb, mrb_value klass)
{
  mrb_int x, y, w, h, color;
  mrb_get_args(mrb, "iiiii", &x, &y, &w, &h, &color);
  dvi_graphics_draw_rect(dvi_get_framebuffer(), dvi_graphics_get_width(), dvi_graphics_get_height(),
                         x, y, w, h, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.fill_circle(cx, cy, r, color)
 */
static mrb_value
mrb_dvi_fill_circle(mrb_state *mrb, mrb_value klass)
{
  mrb_int cx, cy, r, color;
  mrb_get_args(mrb, "iiii", &cx, &cy, &r, &color);
  dvi_graphics_fill_circle(dvi_get_framebuffer(), dvi_graphics_get_width(),
                           dvi_graphics_get_height(), cx, cy, r, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_circle(cx, cy, r, color)
 */
static mrb_value
mrb_dvi_draw_circle(mrb_state *mrb, mrb_value klass)
{
  mrb_int cx, cy, r, color;
  mrb_get_args(mrb, "iiii", &cx, &cy, &r, &color);
  dvi_graphics_draw_circle(dvi_get_framebuffer(), dvi_graphics_get_width(),
                           dvi_graphics_get_height(), cx, cy, r, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.fill_triangle(x0, y0, x1, y1, x2, y2, color)
 */
static mrb_value
mrb_dvi_fill_triangle(mrb_state *mrb, mrb_value klass)
{
  mrb_int x0, y0, x1, y1, x2, y2, color;
  mrb_get_args(mrb, "iiiiiii", &x0, &y0, &x1, &y1, &x2, &y2, &color);
  dvi_graphics_fill_triangle(dvi_get_framebuffer(), dvi_graphics_get_width(),
                             dvi_graphics_get_height(), x0, y0, x1, y1, x2, y2, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.fill_arc(cx, cy, r, start_angle, stop_angle, color)
 */
static mrb_value
mrb_dvi_fill_arc(mrb_state *mrb, mrb_value klass)
{
  mrb_int cx, cy, r, color;
  mrb_float start_angle, stop_angle;
  mrb_get_args(mrb, "iiiffi", &cx, &cy, &r, &start_angle, &stop_angle, &color);
  dvi_graphics_fill_arc(dvi_get_framebuffer(), dvi_graphics_get_width(), dvi_graphics_get_height(),
                        cx, cy, r, (float)start_angle, (float)stop_angle, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_arc(cx, cy, r, start_angle, stop_angle, color)
 */
static mrb_value
mrb_dvi_draw_arc(mrb_state *mrb, mrb_value klass)
{
  mrb_int cx, cy, r, color;
  mrb_float start_angle, stop_angle;
  mrb_get_args(mrb, "iiiffi", &cx, &cy, &r, &start_angle, &stop_angle, &color);
  dvi_graphics_draw_arc(dvi_get_framebuffer(), dvi_graphics_get_width(), dvi_graphics_get_height(),
                        cx, cy, r, (float)start_angle, (float)stop_angle, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.fill_ellipse(cx, cy, rx, ry, color)
 */
static mrb_value
mrb_dvi_fill_ellipse(mrb_state *mrb, mrb_value klass)
{
  mrb_int cx, cy, rx, ry, color;
  mrb_get_args(mrb, "iiiii", &cx, &cy, &rx, &ry, &color);
  dvi_graphics_fill_ellipse(dvi_get_framebuffer(), dvi_graphics_get_width(),
                            dvi_graphics_get_height(), cx, cy, rx, ry, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_ellipse(cx, cy, rx, ry, color)
 */
static mrb_value
mrb_dvi_draw_ellipse(mrb_state *mrb, mrb_value klass)
{
  mrb_int cx, cy, rx, ry, color;
  mrb_get_args(mrb, "iiiii", &cx, &cy, &rx, &ry, &color);
  dvi_graphics_draw_ellipse(dvi_get_framebuffer(), dvi_graphics_get_width(),
                            dvi_graphics_get_height(), cx, cy, rx, ry, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_thick_line(x0, y0, x1, y1, thickness, color)
 */
static mrb_value
mrb_dvi_draw_thick_line(mrb_state *mrb, mrb_value klass)
{
  mrb_int x0, y0, x1, y1, thickness, color;
  mrb_get_args(mrb, "iiiiii", &x0, &y0, &x1, &y1, &thickness, &color);
  dvi_graphics_draw_thick_line(dvi_get_framebuffer(), dvi_graphics_get_width(),
                               dvi_graphics_get_height(), x0, y0, x1, y1, thickness,
                               (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_text(x, y, text, color [, font [, wide_font]])
 */
static mrb_value
mrb_dvi_draw_text(mrb_state *mrb, mrb_value klass)
{
  mrb_int x, y, color;
  mrb_int font_id = DVI_GRAPHICS_FONT_8X8;
  mrb_int wide_font_id = -1;
  const char *text;
  mrb_get_args(mrb, "iizi|ii", &x, &y, &text, &color, &font_id, &wide_font_id);
  const dvi_font_t *font = dvi_graphics_get_font(font_id);
  if (!font) mrb_raise(mrb, E_ARGUMENT_ERROR, "unknown font");
  const dvi_font_t *wide_font = NULL;
  if (wide_font_id >= 0) {
    wide_font = dvi_graphics_get_font(wide_font_id);
    if (!wide_font) mrb_raise(mrb, E_ARGUMENT_ERROR, "unknown wide font");
  }
  dvi_graphics_draw_text(dvi_get_framebuffer(), dvi_graphics_get_width(), dvi_graphics_get_height(),
                         x, y, text, (uint8_t)color, font, wide_font);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.font_height(font)
 */
static mrb_value
mrb_dvi_font_height(mrb_state *mrb, mrb_value klass)
{
  mrb_int font_id;
  mrb_get_args(mrb, "i", &font_id);
  return mrb_fixnum_value(dvi_graphics_font_height(font_id));
}

/*
 * DVI::Graphics.text_width(text [, font [, wide_font]])
 */
static mrb_value
mrb_dvi_text_width(mrb_state *mrb, mrb_value klass)
{
  mrb_int font_id = DVI_GRAPHICS_FONT_8X8;
  mrb_int wide_font_id = -1;
  const char *text;
  mrb_get_args(mrb, "z|ii", &text, &font_id, &wide_font_id);
  const dvi_font_t *font = dvi_graphics_get_font(font_id);
  if (!font) mrb_raise(mrb, E_ARGUMENT_ERROR, "unknown font");
  const dvi_font_t *wide_font = NULL;
  if (wide_font_id >= 0) {
    wide_font = dvi_graphics_get_font(wide_font_id);
    if (!wide_font) mrb_raise(mrb, E_ARGUMENT_ERROR, "unknown wide font");
  }
  return mrb_fixnum_value(dvi_graphics_text_width(text, font, wide_font));
}

/*
 * DVI::Graphics.draw_line(x0, y0, x1, y1, color)
 */
static mrb_value
mrb_dvi_draw_line(mrb_state *mrb, mrb_value klass)
{
  mrb_int x0, y0, x1, y1, color;
  mrb_get_args(mrb, "iiiii", &x0, &y0, &x1, &y1, &color);
  dvi_graphics_draw_line(dvi_get_framebuffer(), dvi_graphics_get_width(), dvi_graphics_get_height(),
                         x0, y0, x1, y1, (uint8_t)color);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_image(data, x, y, w, h)
 */
static mrb_value
mrb_dvi_draw_image(mrb_state *mrb, mrb_value klass)
{
  const char *data;
  mrb_int data_len, x, y, w, h;
  mrb_get_args(mrb, "siiii", &data, &data_len, &x, &y, &w, &h);
  if (data_len < w * h) mrb_raise(mrb, E_ARGUMENT_ERROR, "data too short");
  dvi_graphics_draw_image(dvi_get_framebuffer(), dvi_graphics_get_width(),
                          dvi_graphics_get_height(), (const uint8_t *)data, x, y, w, h);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_image_masked(data, mask, x, y, w, h)
 */
static mrb_value
mrb_dvi_draw_image_masked(mrb_state *mrb, mrb_value klass)
{
  const char *data, *mask;
  mrb_int data_len, mask_len, x, y, w, h;
  mrb_get_args(mrb, "ssiiii", &data, &data_len, &mask, &mask_len, &x, &y, &w, &h);
  if (data_len < w * h) mrb_raise(mrb, E_ARGUMENT_ERROR, "data too short");
  if (mask_len < (w * h + 7) / 8) mrb_raise(mrb, E_ARGUMENT_ERROR, "mask too short");
  dvi_graphics_draw_image_masked(dvi_get_framebuffer(), dvi_graphics_get_width(),
                                 dvi_graphics_get_height(), (const uint8_t *)data,
                                 (const uint8_t *)mask, x, y, w, h);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_image_affine(data, w, h, ox, oy, m00, m01, m10, m11, tx, ty)
 */
static mrb_value
mrb_dvi_draw_image_affine(mrb_state *mrb, mrb_value klass)
{
  const char *data;
  mrb_int data_len, w, h, ox, oy;
  mrb_float m00, m01, m10, m11, tx, ty;
  mrb_get_args(mrb, "siiiiffffff", &data, &data_len, &w, &h, &ox, &oy,
               &m00, &m01, &m10, &m11, &tx, &ty);
  if (data_len < w * h)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "data too short");
  dvi_graphics_draw_image_affine(dvi_get_framebuffer(),
                                 dvi_graphics_get_width(), dvi_graphics_get_height(),
                                 (const uint8_t *)data, w, h, ox, oy,
                                 (float)m00, (float)m01, (float)m10, (float)m11,
                                 (float)tx, (float)ty);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_image_masked_affine(data, mask, w, h, ox, oy, m00, m01, m10, m11, tx, ty)
 */
static mrb_value
mrb_dvi_draw_image_masked_affine(mrb_state *mrb, mrb_value klass)
{
  const char *data, *mask;
  mrb_int data_len, mask_len, w, h, ox, oy;
  mrb_float m00, m01, m10, m11, tx, ty;
  mrb_get_args(mrb, "ssiiiiffffff", &data, &data_len, &mask, &mask_len,
               &w, &h, &ox, &oy,
               &m00, &m01, &m10, &m11, &tx, &ty);
  if (data_len < w * h)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "data too short");
  if (mask_len < (w * h + 7) / 8)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "mask too short");
  dvi_graphics_draw_image_masked_affine(dvi_get_framebuffer(),
                                        dvi_graphics_get_width(), dvi_graphics_get_height(),
                                        (const uint8_t *)data, (const uint8_t *)mask,
                                        w, h, ox, oy,
                                        (float)m00, (float)m01, (float)m10, (float)m11,
                                        (float)tx, (float)ty);
  return mrb_nil_value();
}

/*
 * DVI.text_put_string(col, row, str, attr)
 */
static mrb_value
mrb_dvi_text_put_string(mrb_state *mrb, mrb_value klass)
{
  mrb_int col, row, attr;
  const char *str;
  mrb_get_args(mrb, "iizi", &col, &row, &str, &attr);
  dvi_text_put_string(col, row, str, (uint8_t)attr);
  return mrb_nil_value();
}

/*
 * DVI.text_put_string_bold(col, row, str, attr)
 */
static mrb_value
mrb_dvi_text_put_string_bold(mrb_state *mrb, mrb_value klass)
{
  mrb_int col, row, attr;
  const char *str;
  mrb_get_args(mrb, "iizi", &col, &row, &str, &attr);
  dvi_text_put_string_bold(col, row, str, (uint8_t)attr);
  return mrb_nil_value();
}

/*
 * DVI.text_clear(attr)
 */
static mrb_value
mrb_dvi_text_clear(mrb_state *mrb, mrb_value klass)
{
  mrb_int attr;
  mrb_get_args(mrb, "i", &attr);
  dvi_text_clear((uint8_t)attr);
  return mrb_nil_value();
}

/*
 * DVI.text_put_char(col, row, ch, attr)
 */
static mrb_value
mrb_dvi_text_put_char(mrb_state *mrb, mrb_value klass)
{
  mrb_int col, row, ch, attr;
  mrb_get_args(mrb, "iiii", &col, &row, &ch, &attr);
  dvi_text_put_char(col, row, (char)ch, (uint8_t)attr);
  return mrb_nil_value();
}

/*
 * DVI::Text.commit
 */
static mrb_value
mrb_dvi_text_commit(mrb_state *mrb, mrb_value klass)
{
  dvi_text_commit();
  return mrb_nil_value();
}

/*
 * DVI::Text.scroll_up(lines, attr)
 */
static mrb_value
mrb_dvi_text_scroll_up(mrb_state *mrb, mrb_value klass)
{
  mrb_int lines, attr;
  mrb_get_args(mrb, "ii", &lines, &attr);
  dvi_text_scroll_up(lines, (uint8_t)attr);
  return mrb_nil_value();
}

/*
 * DVI::Text.scroll_down(lines, attr)
 */
static mrb_value
mrb_dvi_text_scroll_down(mrb_state *mrb, mrb_value klass)
{
  mrb_int lines, attr;
  mrb_get_args(mrb, "ii", &lines, &attr);
  dvi_text_scroll_down(lines, (uint8_t)attr);
  return mrb_nil_value();
}

/*
 * DVI::Text.clear_range(col, row, width, attr)
 */
static mrb_value
mrb_dvi_text_clear_range(mrb_state *mrb, mrb_value klass)
{
  mrb_int col, row, width, attr;
  mrb_get_args(mrb, "iiii", &col, &row, &width, &attr);
  dvi_text_clear_range(col, row, width, (uint8_t)attr);
  return mrb_nil_value();
}

/*
 * DVI::Text.clear_line(row, attr)
 */
static mrb_value
mrb_dvi_text_clear_line(mrb_state *mrb, mrb_value klass)
{
  mrb_int row, attr;
  mrb_get_args(mrb, "ii", &row, &attr);
  dvi_text_clear_line(row, (uint8_t)attr);
  return mrb_nil_value();
}

/*
 * DVI::Text.get_attr(col, row) -> Integer
 */
static mrb_value
mrb_dvi_text_get_attr(mrb_state *mrb, mrb_value klass)
{
  mrb_int col, row;
  mrb_get_args(mrb, "ii", &col, &row);
  return mrb_fixnum_value(dvi_text_get_attr(col, row));
}

/*
 * DVI::Text.set_attr(col, row, attr)
 */
static mrb_value
mrb_dvi_text_set_attr(mrb_state *mrb, mrb_value klass)
{
  mrb_int col, row, attr;
  mrb_get_args(mrb, "iii", &col, &row, &attr);
  dvi_text_set_attr(col, row, (uint8_t)attr);
  return mrb_nil_value();
}

/*
 * DVI::Text.read_line(row) -> DVI::Text::Line
 */
static mrb_value
mrb_dvi_text_read_line(mrb_state *mrb, mrb_value klass)
{
  mrb_int row;
  mrb_get_args(mrb, "i", &row);
  if (row < 0 || row >= dvi_text_get_rows()) mrb_raise(mrb, E_ARGUMENT_ERROR, "row out of range");
  struct dvi_text_line *line =
      (struct dvi_text_line *)mrb_malloc(mrb, sizeof(struct dvi_text_line));
  dvi_text_read_line(row, line->cells);
  return mrb_obj_value(mrb_data_object_alloc(mrb, class_Line, line, &dvi_text_line_type));
}

/*
 * DVI::Text.write_line(row, line)
 */
static mrb_value
mrb_dvi_text_write_line(mrb_state *mrb, mrb_value klass)
{
  mrb_int row;
  mrb_value line_obj;
  mrb_get_args(mrb, "io", &row, &line_obj);
  if (row < 0 || row >= dvi_text_get_rows()) mrb_raise(mrb, E_ARGUMENT_ERROR, "row out of range");
  struct dvi_text_line *line =
      (struct dvi_text_line *)mrb_data_get_ptr(mrb, line_obj, &dvi_text_line_type);
  dvi_text_write_line(row, line->cells);
  return mrb_nil_value();
}

/*
 * DVI::Text.set_palette_entry(index, color)
 *   Set a palette entry to an RGB332 color value.
 */
static mrb_value
mrb_dvi_text_set_palette_entry(mrb_state *mrb, mrb_value klass)
{
  mrb_int index, color;
  mrb_get_args(mrb, "ii", &index, &color);
  dvi_text_set_palette_entry((int)index, (uint8_t)color);
  return mrb_nil_value();
}

void
mrb_picoruby_dvi_gem_init(mrb_state *mrb)
{
  struct RClass *class_DVI = mrb_define_class_id(mrb, MRB_SYM(DVI), mrb->object_class);

  mrb_define_const_id(mrb, class_DVI, MRB_SYM(TEXT_MODE), mrb_fixnum_value(DVI_MODE_TEXT));
  mrb_define_const_id(mrb, class_DVI, MRB_SYM(GRAPHICS_MODE), mrb_fixnum_value(DVI_MODE_GRAPHICS));

  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(set_mode), mrb_dvi_set_mode, MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(wait_vsync), mrb_dvi_wait_vsync,
                             MRB_ARGS_NONE());
  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(frame_count), mrb_dvi_frame_count,
                             MRB_ARGS_NONE());

  // DVI::Text
  struct RClass *class_Text =
      mrb_define_class_under_id(mrb, class_DVI, MRB_SYM(Text), mrb->object_class);
  mrb_define_const_id(mrb, class_Text, MRB_SYM(COLS), mrb_fixnum_value(DVI_TEXT_MAX_COLS));
  mrb_define_const_id(mrb, class_Text, MRB_SYM(ROWS), mrb_fixnum_value(DVI_TEXT_MAX_ROWS));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(put_char), mrb_dvi_text_put_char,
                             MRB_ARGS_REQ(4));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(put_string), mrb_dvi_text_put_string,
                             MRB_ARGS_REQ(4));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(put_string_bold),
                             mrb_dvi_text_put_string_bold, MRB_ARGS_REQ(4));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(clear), mrb_dvi_text_clear, MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(commit), mrb_dvi_text_commit,
                             MRB_ARGS_NONE());
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(scroll_up), mrb_dvi_text_scroll_up,
                             MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(scroll_down), mrb_dvi_text_scroll_down,
                             MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(clear_range), mrb_dvi_text_clear_range,
                             MRB_ARGS_REQ(4));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(clear_line), mrb_dvi_text_clear_line,
                             MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(get_attr), mrb_dvi_text_get_attr,
                             MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(set_attr), mrb_dvi_text_set_attr,
                             MRB_ARGS_REQ(3));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(read_line), mrb_dvi_text_read_line,
                             MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(write_line), mrb_dvi_text_write_line,
                             MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(set_palette_entry),
                             mrb_dvi_text_set_palette_entry, MRB_ARGS_REQ(2));

  // DVI::Text::Line (opaque container for scrollback)
  class_Line = mrb_define_class_under_id(mrb, class_Text, MRB_SYM(Line), mrb->object_class);
  MRB_SET_INSTANCE_TT(class_Line, MRB_TT_CDATA);

  // DVI::Graphics
  struct RClass *class_Graphics =
      mrb_define_class_under_id(mrb, class_DVI, MRB_SYM(Graphics), mrb->object_class);
  DVI_FONT_DEFINE_RUBY_CONSTANTS(mrb, class_Graphics);

  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(width), mrb_dvi_graphics_width,
                             MRB_ARGS_NONE());
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(height), mrb_dvi_graphics_height,
                             MRB_ARGS_NONE());
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(set_resolution), mrb_dvi_set_resolution,
                             MRB_ARGS_REQ(2));

  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(BLEND_REPLACE),
                      mrb_fixnum_value(DVI_BLEND_REPLACE));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(BLEND_ADD), mrb_fixnum_value(DVI_BLEND_ADD));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(BLEND_SUBTRACT),
                      mrb_fixnum_value(DVI_BLEND_SUBTRACT));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(BLEND_MULTIPLY),
                      mrb_fixnum_value(DVI_BLEND_MULTIPLY));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(BLEND_SCREEN),
                      mrb_fixnum_value(DVI_BLEND_SCREEN));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(BLEND_ALPHA), mrb_fixnum_value(DVI_BLEND_ALPHA));

  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(set_blend_mode), mrb_dvi_set_blend_mode,
                             MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(set_alpha), mrb_dvi_set_alpha,
                             MRB_ARGS_REQ(1));

  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(commit), mrb_dvi_graphics_commit,
                             MRB_ARGS_NONE());

  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(set_pixel), mrb_dvi_set_pixel,
                             MRB_ARGS_REQ(3));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(get_pixel), mrb_dvi_get_pixel,
                             MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill), mrb_dvi_fill, MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill_rect), mrb_dvi_fill_rect,
                             MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_rect), mrb_dvi_draw_rect,
                             MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill_circle), mrb_dvi_fill_circle,
                             MRB_ARGS_REQ(4));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_circle), mrb_dvi_draw_circle,
                             MRB_ARGS_REQ(4));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill_arc), mrb_dvi_fill_arc,
                             MRB_ARGS_REQ(6));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_arc), mrb_dvi_draw_arc,
                             MRB_ARGS_REQ(6));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill_triangle), mrb_dvi_fill_triangle,
                             MRB_ARGS_REQ(7));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill_ellipse), mrb_dvi_fill_ellipse,
                             MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_ellipse), mrb_dvi_draw_ellipse,
                             MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_thick_line), mrb_dvi_draw_thick_line,
                             MRB_ARGS_REQ(6));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_text), mrb_dvi_draw_text,
                             MRB_ARGS_ARG(4, 2));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(text_width), mrb_dvi_text_width,
                             MRB_ARGS_ARG(1, 2));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(font_height), mrb_dvi_font_height,
                             MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_line), mrb_dvi_draw_line,
                             MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_image), mrb_dvi_draw_image,
                             MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_image_masked),
                             mrb_dvi_draw_image_masked, MRB_ARGS_REQ(6));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_image_affine),
                             mrb_dvi_draw_image_affine, MRB_ARGS_REQ(11));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_image_masked_affine),
                             mrb_dvi_draw_image_masked_affine, MRB_ARGS_REQ(12));
}

void
mrb_picoruby_dvi_gem_final(mrb_state *mrb)
{
}
