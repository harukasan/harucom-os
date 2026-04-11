#include "dict_region.h"

#if defined(PICORB_VM_MRUBY)

#include "mruby/dict_region.c"

#else

#error "harucom-os-dict only supports mruby VM"

#endif
