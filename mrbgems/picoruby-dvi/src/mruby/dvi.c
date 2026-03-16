#include <mruby.h>
#include <mruby/presym.h>

void
mrb_picoruby_dvi_gem_init(mrb_state *mrb)
{
  mrb_define_class_id(mrb, MRB_SYM(DVI), mrb->object_class);
}

void
mrb_picoruby_dvi_gem_final(mrb_state *mrb)
{
}
