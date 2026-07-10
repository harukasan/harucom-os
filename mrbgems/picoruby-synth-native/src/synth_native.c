/*
 * picoruby-synth/src/synth_native.c
 *
 * Synth::Native: float buffer kernels behind the Synth render DSL
 * (rootfs/lib/synth.rb). Each kernel is one whole-buffer pass in C,
 * replacing the interpreted per-sample loops that make pure-Ruby
 * rendering take seconds per sound on the board. The Ruby layer keeps
 * the same API and falls back to its own loops where this gem is not
 * present (host CRuby).
 */

#if defined(PICORB_VM_MRUBY)
#include "mruby/synth_native.c"
#endif
