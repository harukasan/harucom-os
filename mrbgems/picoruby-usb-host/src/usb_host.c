#include "usb_host.h"

#if defined(PICORB_VM_MRUBY)

#include "mruby/usb_host.c"

#else

#error "picoruby-usb-host only supports mruby VM"

#endif
