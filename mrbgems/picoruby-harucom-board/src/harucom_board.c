/*
 * picoruby-harucom-board/src/harucom_board.c
 *
 * Board: pin constants for the Harucom Board. The values come from the
 * board header include/boards/harucom_board.h so the Ruby constants and
 * the C build stay in sync. This gem only defines integer constants, so
 * there is no hardware code and no ports/ layer.
 */

#if defined(PICORB_VM_MRUBY)
#include "mruby/harucom_board.c"
#endif
