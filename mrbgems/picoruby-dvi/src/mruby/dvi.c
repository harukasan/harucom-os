#include <string.h>

#include <mruby.h>
#include <mruby/presym.h>

#include "dvi.h"

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
  if (x < 0 || x >= DVI_FRAME_WIDTH || y < 0 || y >= DVI_FRAME_HEIGHT)
    return mrb_nil_value();
  dvi_get_framebuffer()[y * DVI_FRAME_WIDTH + x] = (uint8_t)color;
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
  if (x < 0 || x >= DVI_FRAME_WIDTH || y < 0 || y >= DVI_FRAME_HEIGHT)
    return mrb_fixnum_value(0);
  return mrb_fixnum_value(dvi_get_framebuffer()[y * DVI_FRAME_WIDTH + x]);
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
         DVI_FRAME_WIDTH * DVI_FRAME_HEIGHT);
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
  if (x + w > DVI_FRAME_WIDTH) w = DVI_FRAME_WIDTH - x;
  if (y + h > DVI_FRAME_HEIGHT) h = DVI_FRAME_HEIGHT - y;
  if (w <= 0 || h <= 0) return mrb_nil_value();
  for (mrb_int iy = 0; iy < h; iy++) {
    memset(&fb[(y + iy) * DVI_FRAME_WIDTH + x], c, w);
  }
  return mrb_nil_value();
}

void
mrb_picoruby_dvi_gem_init(mrb_state *mrb)
{
  struct RClass *class_DVI =
      mrb_define_class_id(mrb, MRB_SYM(DVI), mrb->object_class);

  mrb_define_const_id(mrb, class_DVI, MRB_SYM(WIDTH),
                      mrb_fixnum_value(DVI_FRAME_WIDTH));
  mrb_define_const_id(mrb, class_DVI, MRB_SYM(HEIGHT),
                      mrb_fixnum_value(DVI_FRAME_HEIGHT));

  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(wait_vsync),
                             mrb_dvi_wait_vsync, MRB_ARGS_NONE());
  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(frame_count),
                             mrb_dvi_frame_count, MRB_ARGS_NONE());
  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(set_pixel),
                             mrb_dvi_set_pixel, MRB_ARGS_REQ(3));
  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(get_pixel),
                             mrb_dvi_get_pixel, MRB_ARGS_REQ(2));
  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(fill), mrb_dvi_fill,
                             MRB_ARGS_REQ(1));
  mrb_define_class_method_id(mrb, class_DVI, MRB_SYM(fill_rect),
                             mrb_dvi_fill_rect, MRB_ARGS_REQ(5));
}

void
mrb_picoruby_dvi_gem_final(mrb_state *mrb)
{
}
