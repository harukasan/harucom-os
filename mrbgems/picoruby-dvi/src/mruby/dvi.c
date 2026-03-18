#include <string.h>

#include <mruby.h>
#include <mruby/presym.h>

#include "dvi.h"

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

  // DVI::Graphics
  struct RClass *class_Graphics =
      mrb_define_class_under_id(mrb, class_DVI, MRB_SYM(Graphics),
                                mrb->object_class);
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(WIDTH),
                      mrb_fixnum_value(DVI_GRAPHICS_WIDTH));
  mrb_define_const_id(mrb, class_Graphics, MRB_SYM(HEIGHT),
                      mrb_fixnum_value(DVI_GRAPHICS_HEIGHT));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(set_pixel),
                             mrb_dvi_set_pixel, MRB_ARGS_REQ(3));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(get_pixel),
                             mrb_dvi_get_pixel, MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill),
                             mrb_dvi_fill, MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_Graphics, MRB_SYM(fill_rect),
                             mrb_dvi_fill_rect, MRB_ARGS_REQ(5));
}

void
mrb_picoruby_dvi_gem_final(mrb_state *mrb)
{
}
