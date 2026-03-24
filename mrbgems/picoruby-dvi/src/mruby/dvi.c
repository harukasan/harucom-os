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

static const mrb_data_type dvi_text_line_type = {
  "DVI::Text::Line", dvi_text_line_free
};

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
 * DVI.set_pixel(x, y, color)
 */
static mrb_value
mrb_dvi_set_pixel(mrb_state *mrb, mrb_value klass)
{
  mrb_int x, y, color;
  mrb_get_args(mrb, "iii", &x, &y, &color);
  if (x < 0 || x >= DVI_GRAPHICS_WIDTH || y < 0 || y >= DVI_GRAPHICS_HEIGHT)
    return mrb_nil_value();
  dvi_get_framebuffer()[y * DVI_GRAPHICS_WIDTH + x] = (uint8_t)color;
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
  if (x < 0 || x >= DVI_GRAPHICS_WIDTH || y < 0 || y >= DVI_GRAPHICS_HEIGHT)
    return mrb_fixnum_value(0);
  return mrb_fixnum_value(dvi_get_framebuffer()[y * DVI_GRAPHICS_WIDTH + x]);
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
         DVI_GRAPHICS_WIDTH * DVI_GRAPHICS_HEIGHT);
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
  uint8_t *fb = dvi_get_framebuffer();
  uint8_t c = (uint8_t)color;
  /* Clip to framebuffer bounds */
  if (x < 0) { w += x; x = 0; }
  if (y < 0) { h += y; y = 0; }
  if (x + w > DVI_GRAPHICS_WIDTH) w = DVI_GRAPHICS_WIDTH - x;
  if (y + h > DVI_GRAPHICS_HEIGHT) h = DVI_GRAPHICS_HEIGHT - y;
  if (w <= 0 || h <= 0) return mrb_nil_value();
  for (mrb_int iy = 0; iy < h; iy++) {
    memset(&fb[(y + iy) * DVI_GRAPHICS_WIDTH + x], c, w);
  }
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_text(x, y, text, color [, font])
 */
static mrb_value
mrb_dvi_draw_text(mrb_state *mrb, mrb_value klass)
{
  mrb_int x, y, color, font_id = DVI_GRAPHICS_FONT_8X8;
  const char *text;
  mrb_get_args(mrb, "iizi|i", &x, &y, &text, &color, &font_id);
  const dvi_font_t *font = dvi_graphics_get_font(font_id);
  if (!font)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "unknown font");
  dvi_graphics_draw_text(dvi_get_framebuffer(),
                         DVI_GRAPHICS_WIDTH, DVI_GRAPHICS_HEIGHT,
                         x, y, text, (uint8_t)color, font);
  return mrb_nil_value();
}

/*
 * DVI::Graphics.draw_line(x0, y0, x1, y1, color)
 */
static mrb_value
mrb_dvi_draw_line(mrb_state *mrb, mrb_value klass)
{
  mrb_int x0, y0, x1, y1, color;
  mrb_get_args(mrb, "iiiii", &x0, &y0, &x1, &y1, &color);
  dvi_graphics_draw_line(dvi_get_framebuffer(),
                         DVI_GRAPHICS_WIDTH, DVI_GRAPHICS_HEIGHT,
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
  if (data_len < w * h)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "data too short");
  dvi_graphics_draw_image(dvi_get_framebuffer(),
                          DVI_GRAPHICS_WIDTH, DVI_GRAPHICS_HEIGHT,
                          (const uint8_t *)data, x, y, w, h);
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
  mrb_get_args(mrb, "ssiiii", &data, &data_len, &mask, &mask_len,
               &x, &y, &w, &h);
  if (data_len < w * h)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "data too short");
  if (mask_len < (w * h + 7) / 8)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "mask too short");
  dvi_graphics_draw_image_masked(dvi_get_framebuffer(),
                                 DVI_GRAPHICS_WIDTH, DVI_GRAPHICS_HEIGHT,
                                 (const uint8_t *)data, (const uint8_t *)mask,
                                 x, y, w, h);
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
  if (row < 0 || row >= dvi_text_get_rows())
    mrb_raise(mrb, E_ARGUMENT_ERROR, "row out of range");
  struct dvi_text_line *line =
      (struct dvi_text_line *)mrb_malloc(mrb, sizeof(struct dvi_text_line));
  dvi_text_read_line(row, line->cells);
  return mrb_obj_value(
      mrb_data_object_alloc(mrb, class_Line, line, &dvi_text_line_type));
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
  if (row < 0 || row >= dvi_text_get_rows())
    mrb_raise(mrb, E_ARGUMENT_ERROR, "row out of range");
  struct dvi_text_line *line =
      (struct dvi_text_line *)mrb_data_get_ptr(mrb, line_obj, &dvi_text_line_type);
  dvi_text_write_line(row, line->cells);
  return mrb_nil_value();
}

void
mrb_picoruby_dvi_gem_init(mrb_state *mrb)
{
  struct RClass *class_DVI =
      mrb_define_class_id(mrb, MRB_SYM(DVI), mrb->object_class);

  mrb_define_const_id(mrb, class_DVI, MRB_SYM(TEXT_MODE),
                      mrb_fixnum_value(DVI_MODE_TEXT));
  mrb_define_const_id(mrb, class_DVI, MRB_SYM(GRAPHICS_MODE),
                      mrb_fixnum_value(DVI_MODE_GRAPHICS));

  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(set_mode),
                             mrb_dvi_set_mode, MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(wait_vsync),
                             mrb_dvi_wait_vsync, MRB_ARGS_NONE());
  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(frame_count),
                             mrb_dvi_frame_count, MRB_ARGS_NONE());

  // DVI::Text
  struct RClass *class_Text =
      mrb_define_class_under_id(mrb, class_DVI, MRB_SYM(Text),
                                mrb->object_class);
  mrb_define_const_id(mrb, class_Text, MRB_SYM(COLS),
                      mrb_fixnum_value(DVI_TEXT_MAX_COLS));
  mrb_define_const_id(mrb, class_Text, MRB_SYM(ROWS),
                      mrb_fixnum_value(DVI_TEXT_MAX_ROWS));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(put_char),
                             mrb_dvi_text_put_char, MRB_ARGS_REQ(4));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(put_string),
                             mrb_dvi_text_put_string, MRB_ARGS_REQ(4));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(clear),
                             mrb_dvi_text_clear, MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(commit),
                             mrb_dvi_text_commit, MRB_ARGS_NONE());
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(scroll_up),
                             mrb_dvi_text_scroll_up, MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(scroll_down),
                             mrb_dvi_text_scroll_down, MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(clear_range),
                             mrb_dvi_text_clear_range, MRB_ARGS_REQ(4));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(clear_line),
                             mrb_dvi_text_clear_line, MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(get_attr),
                             mrb_dvi_text_get_attr, MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(set_attr),
                             mrb_dvi_text_set_attr, MRB_ARGS_REQ(3));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(read_line),
                             mrb_dvi_text_read_line, MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_Text, MRB_SYM(write_line),
                             mrb_dvi_text_write_line, MRB_ARGS_REQ(2));

  // DVI::Text::Line (opaque container for scrollback)
  class_Line = mrb_define_class_under_id(mrb, class_Text, MRB_SYM(Line),
                                          mrb->object_class);
  MRB_SET_INSTANCE_TT(class_Line, MRB_TT_CDATA);

  // DVI::Graphics
  struct RClass *class_Graphics =
      mrb_define_class_under_id(mrb, class_DVI, MRB_SYM(Graphics),
                                mrb->object_class);
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(WIDTH),
                      mrb_fixnum_value(DVI_GRAPHICS_WIDTH));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(HEIGHT),
                      mrb_fixnum_value(DVI_GRAPHICS_HEIGHT));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(FONT_8X8),
                      mrb_fixnum_value(DVI_GRAPHICS_FONT_8X8));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(FONT_MPLUS_12),
                      mrb_fixnum_value(DVI_GRAPHICS_FONT_12PX));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(FONT_FIXED_4X6),
                      mrb_fixnum_value(DVI_GRAPHICS_FONT_FIXED_4X6));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(FONT_FIXED_5X7),
                      mrb_fixnum_value(DVI_GRAPHICS_FONT_FIXED_5X7));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(FONT_FIXED_6X13),
                      mrb_fixnum_value(DVI_GRAPHICS_FONT_FIXED_6X13));

  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(set_pixel),
                             mrb_dvi_set_pixel, MRB_ARGS_REQ(3));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(get_pixel),
                             mrb_dvi_get_pixel, MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill),
                             mrb_dvi_fill, MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill_rect),
                             mrb_dvi_fill_rect, MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_text),
                             mrb_dvi_draw_text, MRB_ARGS_ARG(4, 1));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_line),
                             mrb_dvi_draw_line, MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_image),
                             mrb_dvi_draw_image, MRB_ARGS_REQ(5));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(draw_image_masked),
                             mrb_dvi_draw_image_masked, MRB_ARGS_REQ(6));
}

void
mrb_picoruby_dvi_gem_final(mrb_state *mrb)
{
}
