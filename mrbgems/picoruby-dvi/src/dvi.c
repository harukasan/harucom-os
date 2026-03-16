#include "../include/dvi.h"

#if defined(PICORB_VM_MRUBY)

#include "mruby/dvi.c"

#else

#error "picoruby-dvi only supports mruby VM"

#endif
