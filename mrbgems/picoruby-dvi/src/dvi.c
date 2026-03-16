#include "../include/dvi.h"

#if defined(PICORB_VM_MRUBY)

#include "mruby/dvi.c"

#elif defined(PICORB_VM_MRUBYC)

#include "mrubyc/dvi.c"

#endif
